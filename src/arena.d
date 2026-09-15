module arena;

// Struct-only bump/arena allocator. No classes, no GC in hot path.
// Chunks are reused via reset(); freeAll() releases to OS.
import core.stdc.stdlib : malloc, free;

struct Arena
{
nothrow @nogc:
    void** chunks = null;
    size_t nchunks = 0;
    size_t capChunks = 0;
    ubyte* curPtr = null;
    size_t curLeft = 0;

    enum size_t ChunkSize = 1024 * 1024;

    void* alloc(size_t n)
    {
        if (n == 0)
            return null;
        n = (n + 15) & ~cast(size_t)15;
        if (n > curLeft)
        {
            if (n > ChunkSize)
                return null; // v1: reject oversize, caller falls back
            if (nchunks == capChunks)
            {
                size_t ncap = capChunks == 0 ? 4 : capChunks * 2;
                void** p = cast(void**)malloc(ncap * (void*).sizeof);
                if (!p)
                    return null;
                for (size_t i = 0; i < nchunks; i++)
                    p[i] = chunks[i];
                if (chunks)
                    free(chunks);
                chunks = p;
                capChunks = ncap;
            }
            void* h = malloc(ChunkSize);
            if (!h)
                return null;
            chunks[nchunks++] = h;
            curPtr = cast(ubyte*)h;
            curLeft = ChunkSize;
        }
        void* r = curPtr;
        curPtr += n;
        curLeft -= n;
        return r;
    }

    void reset()
    {
        // Rewind to chunk 0 and release any extra chunks. (Only dropping
        // nchunks would orphan them: they'd never be freed nor reused.)
        if (nchunks > 0)
        {
            for (size_t i = 1; i < nchunks; i++)
                free(chunks[i]);
            curPtr = cast(ubyte*)chunks[0];
            curLeft = ChunkSize;
            nchunks = 1;
        }
    }

    // High-water mark for the universe cache: analysis data stays live in
    // scratch across requests while per-request temporaries (completion
    // items) are dropped by rewinding. Only valid until reset()/freeAll().
    struct Mark
    {
        size_t nchunks;
        ubyte* ptr;
        size_t left;
    }

    Mark mark()
    {
        return Mark(nchunks, curPtr, curLeft);
    }

    void rewind(Mark mk)
    {
        for (size_t i = mk.nchunks; i < nchunks; i++)
            free(chunks[i]);
        nchunks = mk.nchunks;
        if (nchunks == 0)
        {
            curPtr = null;
            curLeft = 0;
        }
        else
        {
            curPtr = mk.ptr;
            curLeft = mk.left;
        }
    }

    void freeAll()
    {
        for (size_t i = 0; i < nchunks; i++)
            free(chunks[i]);
        if (chunks)
            free(chunks);
        chunks = null;
        nchunks = 0;
        capChunks = 0;
        curPtr = null;
        curLeft = 0;
    }
}
