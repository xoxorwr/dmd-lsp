// Minimal JSON parser (cJSON-style), vendored from kdom's rt.json and
// adapted to this codebase: `Arena` allocator, `core.stdc` libc, no phobos,
// no `rt.*`. Member `key` (kdom: `string`, a D keyword) renamed; leading-dot
// module calls spelled out; private free functions suffixed `_impl`.
// NOTE: all `const(char)*` strings owned by a tree must be NUL-terminated
// (the parser guarantees this for decoded strings; builders must too).
module json;

import arena;
import core.stdc.string : strlen, strcmp, strncmp, memcpy, memset, strcpy;
import core.stdc.stdlib : strtod;
import core.stdc.ctype : tolower;
import core.stdc.stdio : snprintf;

// Arena-backed allocator matching the Allocator shape the parser expects.
struct Allocator
{
    Arena* arena;

    T[] alloc(T)(size_t n)
    {
        if (!arena || n == 0)
            return null;
        auto p = cast(T*)arena.alloc(n * T.sizeof);
        return p ? p[0 .. n] : null;
    }
}

enum JsonInvalid = 0;
enum JsonFalse  = (1 << 0);
enum JsonTrue   = (1 << 1);
enum JsonNull   = (1 << 2);
enum JsonNumber = (1 << 3);
enum JsonString = (1 << 4);
enum JsonArray  = (1 << 5);
enum JsonObject = (1 << 6);
enum JsonRaw    = (1 << 7);

enum JsonIsReference   = 256;
enum JsonStringIsConst = 512;

enum NESTING_LIMIT  = 1000;
enum CIRCULAR_LIMIT = 10000;

struct JsonNode
{
    JsonNode* next;
    JsonNode* prev;
    JsonNode* child;
    int type;
    char* value_string;
    int value_integer;
    double value_number;
    char* key;
}

private __gshared const(char)* global_error_json;
private __gshared size_t global_error_pos;

const(char)* get_error_ptr()
{
    return global_error_json + global_error_pos;
}

private struct ParseBuffer
{
    const(char)* content;
    size_t length;
    size_t offset;
    size_t depth;
    Allocator alloc;
}

private bool can_read(ParseBuffer* buf, size_t n)
{
    return buf !is null && (buf.offset + n) <= buf.length;
}

private bool can_access_at_index(ParseBuffer* buf, size_t idx)
{
    return buf !is null && (buf.offset + idx) < buf.length;
}

private const(char)* buffer_at_offset(ParseBuffer* buf)
{
    return buf.content + buf.offset;
}

private int cstrcmp_nocase(const(char)* s1, const(char)* s2)
{
    if (s1 is null || s2 is null)
        return 1;
    if (s1 == s2)
        return 0;

    for (; tolower(cast(int)*s1) == tolower(cast(int)*s2); s1++, s2++)
    {
        if (*s1 == '\0')
            return 0;
    }
    return tolower(cast(int)*s1) - tolower(cast(int)*s2);
}

private double dabs(double x)
{
    return x < 0 ? -x : x;
}

private bool compare_double(double a, double b)
{
    double maxVal = dabs(a) > dabs(b) ? dabs(a) : dabs(b);
    return (dabs(a - b) <= maxVal * 2.2204460492503131e-16);
}

private char* json_strdup(Allocator alloc, const(char)* str)
{
    if (str is null)
        return null;

    auto len = strlen(str) + 1;
    auto copy = alloc.alloc!(char)(len);
    if (copy.ptr is null)
        return null;
    memcpy(copy.ptr, str, len);
    return copy.ptr;
}

private JsonNode* new_item(Allocator alloc)
{
    auto buf = alloc.alloc!(ubyte)(JsonNode.sizeof);
    auto node = cast(JsonNode*)buf.ptr;
    if (node is null)
        return null;
    memset(node, 0, JsonNode.sizeof);
    return node;
}

private void suffix_object(JsonNode* prev, JsonNode* item_)
{
    prev.next = item_;
    item_.prev = prev;
}

private JsonNode* create_reference(JsonNode* item_, Allocator alloc)
{
    if (item_ is null)
        return null;

    auto ref_ = new_item(alloc);
    if (ref_ is null)
        return null;

    memcpy(ref_, item_, JsonNode.sizeof);
    ref_.key = null;
    ref_.type |= JsonIsReference;
    ref_.next = null;
    ref_.prev = null;
    return ref_;
}

private ParseBuffer* buffer_skip_whitespace(ParseBuffer* buf)
{
    if (buf is null || buf.content is null)
        return null;

    if (!can_access_at_index(buf, 0))
        return buf;

    while (can_access_at_index(buf, 0))
    {
        if (cast(ubyte)buffer_at_offset(buf)[0] <= 32)
        {
            buf.offset++;
            continue;
        }

        // Treat C-style comments as whitespace (lenient superset).
        if (can_access_at_index(buf, 1) && buffer_at_offset(buf)[0] == '/')
        {
            if (buffer_at_offset(buf)[1] == '/')
            {
                buf.offset += 2;
                while (can_access_at_index(buf, 0) && buffer_at_offset(buf)[0] != '\n')
                    buf.offset++;
                continue;
            }
            else if (buffer_at_offset(buf)[1] == '*')
            {
                buf.offset += 2;
                while (can_access_at_index(buf, 1))
                {
                    if (buffer_at_offset(buf)[0] == '*' && buffer_at_offset(buf)[1] == '/')
                    {
                        buf.offset += 2;
                        break;
                    }
                    buf.offset++;
                }
                continue;
            }
        }

        break;
    }

    if (buf.offset == buf.length)
        buf.offset--;

    return buf;
}

private ParseBuffer* skip_utf8_bom(ParseBuffer* buf)
{
    if (buf is null || buf.content is null || buf.offset != 0)
        return null;

    if (can_access_at_index(buf, 4) && strncmp(buffer_at_offset(buf), "\xEF\xBB\xBF", 3) == 0)
        buf.offset += 3;

    return buf;
}

// Decode a config file's bytes to UTF-8: UTF-16 with or without a BOM is
// transcoded; a UTF-8 BOM is left to the parser.
string decodeJsonText(const(char)[] s)
{
    if (s.length >= 2 && cast(ubyte)s[0] == 0xFF && cast(ubyte)s[1] == 0xFE)
        return utf16ToUtf8(s, false);
    if (s.length >= 2 && cast(ubyte)s[0] == 0xFE && cast(ubyte)s[1] == 0xFF)
        return utf16ToUtf8(s, true);
    if (s.length >= 6 && s[1] == 0 && s[3] == 0 &&
        (s[0] == '{' || s[0] == '[' || s[0] == ' ' || s[0] == '\r' || s[0] == '\n'))
        return utf16ToUtf8(s, false); // BOM-less UTF-16LE
    if (s.length >= 6 && s[0] == 0 && s[2] == 0 &&
        (s[1] == '{' || s[1] == '[' || s[1] == ' ' || s[1] == '\r' || s[1] == '\n'))
        return utf16ToUtf8(s, true); // BOM-less UTF-16BE
    return s.idup;
}

private string utf16ToUtf8(const(char)[] s, bool bigEndian)
{
    string out_;
    size_t i = (s.length >= 2 &&
        ((cast(ubyte)s[0] == 0xFF && cast(ubyte)s[1] == 0xFE) ||
         (cast(ubyte)s[0] == 0xFE && cast(ubyte)s[1] == 0xFF))) ? 2 : 0;
    while (i + 1 < s.length)
    {
        uint u = bigEndian
            ? (cast(uint)cast(ubyte)s[i] << 8) | cast(ubyte)s[i + 1]
            : (cast(uint)cast(ubyte)s[i + 1] << 8) | cast(ubyte)s[i];
        i += 2;
        if (u >= 0xD800 && u <= 0xDBFF && i + 1 < s.length)
        {
            uint lo = bigEndian
                ? (cast(uint)cast(ubyte)s[i] << 8) | cast(ubyte)s[i + 1]
                : (cast(uint)cast(ubyte)s[i + 1] << 8) | cast(ubyte)s[i];
            if (lo >= 0xDC00 && lo <= 0xDFFF)
            {
                i += 2;
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
            }
        }
        if (u < 0x80)
            out_ ~= cast(char) u;
        else if (u < 0x800)
        {
            out_ ~= cast(char)(0xC0 | (u >> 6));
            out_ ~= cast(char)(0x80 | (u & 0x3F));
        }
        else if (u < 0x10000)
        {
            out_ ~= cast(char)(0xE0 | (u >> 12));
            out_ ~= cast(char)(0x80 | ((u >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (u & 0x3F));
        }
        else
        {
            out_ ~= cast(char)(0xF0 | (u >> 18));
            out_ ~= cast(char)(0x80 | ((u >> 12) & 0x3F));
            out_ ~= cast(char)(0x80 | ((u >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (u & 0x3F));
        }
    }
    return out_;
}

unittest
{
    assert(decodeJsonText(`{"a":1}`) == `{"a":1}`);
    assert(decodeJsonText("\xEF\xBB\xBF{\"a\":1}") == "\xEF\xBB\xBF{\"a\":1}");
    assert(decodeJsonText("\xFF\xFE{\x00\"\x00a\x00\"\x00:\x001\x00}\x00")
        == `{"a":1}`); // UTF-16LE + BOM
    assert(decodeJsonText("{\x00\"\x00a\x00\"\x00:\x001\x00}\x00")
        == `{"a":1}`); // BOM-less UTF-16LE
    assert(decodeJsonText("\xFE\xFF\x00{\x00\"\x00a\x00\"\x00:\x001\x00}")
        == `{"a":1}`); // UTF-16BE + BOM
    assert(decodeJsonText("\x00{\x00\"\x00a\x00\"\x00:\x001\x00}")
        == `{"a":1}`); // BOM-less UTF-16BE
}

private uint parse_hex4(const(char)* input)
{
    uint h = 0;
    for (int i = 0; i < 4; i++)
    {
        if (input[i] >= '0' && input[i] <= '9')
            h += cast(uint)input[i] - '0';
        else if (input[i] >= 'A' && input[i] <= 'F')
            h += cast(uint)10 + input[i] - 'A';
        else if (input[i] >= 'a' && input[i] <= 'f')
            h += cast(uint)10 + input[i] - 'a';
        else
            return 0;

        if (i < 3)
            h = h << 4;
    }
    return h;
}

private ubyte utf16_literal_to_utf8(const(char)* input_pointer, const(char)* input_end, ref char* output_pointer)
{
    ulong codepoint = 0;
    uint first_code = 0;
    const(char)* first_sequence = input_pointer;
    ubyte utf8_length = 0;
    ubyte utf8_position = 0;
    ubyte sequence_length = 0;
    ubyte first_byte_mark = 0;

    if ((input_end - first_sequence) < 6)
        goto fail;

    first_code = parse_hex4(first_sequence + 2);

    if ((first_code >= 0xDC00) && (first_code <= 0xDFFF))
        goto fail;

    if ((first_code >= 0xD800) && (first_code <= 0xDBFF))
    {
        const(char)* second_sequence = first_sequence + 6;
        uint second_code = 0;
        sequence_length = 12;

        if ((input_end - second_sequence) < 6)
            goto fail;

        if (second_sequence[0] != '\\' || second_sequence[1] != 'u')
            goto fail;

        second_code = parse_hex4(second_sequence + 2);
        if (second_code < 0xDC00 || second_code > 0xDFFF)
            goto fail;

        codepoint = 0x10000 + (((first_code & 0x3FF) << 10) | (second_code & 0x3FF));
    }
    else
    {
        sequence_length = 6;
        codepoint = first_code;
    }

    if (codepoint < 0x80)
    {
        utf8_length = 1;
    }
    else if (codepoint < 0x800)
    {
        utf8_length = 2;
        first_byte_mark = 0xC0;
    }
    else if (codepoint < 0x10000)
    {
        utf8_length = 3;
        first_byte_mark = 0xE0;
    }
    else if (codepoint <= 0x10FFFF)
    {
        utf8_length = 4;
        first_byte_mark = 0xF0;
    }
    else
    {
        goto fail;
    }

    for (utf8_position = cast(ubyte)(utf8_length - 1); utf8_position > 0; utf8_position--)
    {
        output_pointer[utf8_position] = cast(char)((codepoint | 0x80) & 0xBF);
        codepoint >>= 6;
    }
    if (utf8_length > 1)
        output_pointer[0] = cast(char)((codepoint | first_byte_mark) & 0xFF);
    else
        output_pointer[0] = cast(char)(codepoint & 0x7F);

    output_pointer += utf8_length;
    return sequence_length;

fail:
    return 0;
}

private bool parse_number(JsonNode* item_, ParseBuffer* input_buffer)
{
    double number = 0;
    char* after_end = null;
    size_t number_string_length = 0;

    if (input_buffer is null || input_buffer.content is null)
        return false;

    for (size_t i = 0; can_access_at_index(input_buffer, i); i++)
    {
        auto c = buffer_at_offset(input_buffer)[i];
        if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == 'e' || c == 'E')
            number_string_length++;
        else if (c == '.')
            number_string_length++;
        else
            break;
    }

    auto number_c_string = input_buffer.alloc.alloc!(char)(number_string_length + 1);
    if (number_c_string.ptr is null)
        return false;

    memcpy(number_c_string.ptr, buffer_at_offset(input_buffer), number_string_length);
    number_c_string[number_string_length] = '\0';

    number = strtod(number_c_string.ptr, &after_end);
    if (number_c_string.ptr == after_end)
        return false;

    item_.value_number = number;

    if (number >= int.max)
        item_.value_integer = int.max;
    else if (number <= cast(double)int.min)
        item_.value_integer = int.min;
    else
        item_.value_integer = cast(int)number;

    item_.type = JsonNumber;

    input_buffer.offset += cast(size_t)(after_end - number_c_string.ptr);
    return true;
}

private bool parse_string(JsonNode* item_, ParseBuffer* input_buffer)
{
    const(char)* input_pointer = buffer_at_offset(input_buffer) + 1;
    const(char)* input_end = buffer_at_offset(input_buffer) + 1;
    char* output_pointer = null;
    char[] output;

    if (buffer_at_offset(input_buffer)[0] != '"')
        goto fail;

    {
        size_t allocation_length = 0;
        size_t skipped_bytes = 0;
        while ((cast(size_t)(input_end - input_buffer.content) < input_buffer.length) && (*input_end != '"'))
        {
            if (input_end[0] == '\\')
            {
                if ((cast(size_t)(input_end + 1 - input_buffer.content) >= input_buffer.length))
                    goto fail;
                skipped_bytes++;
                input_end++;
            }
            input_end++;
        }
        if ((cast(size_t)(input_end - input_buffer.content) >= input_buffer.length) || (*input_end != '"'))
            goto fail;

        allocation_length = cast(size_t)(input_end - buffer_at_offset(input_buffer)) - skipped_bytes;
        output = input_buffer.alloc.alloc!(char)(allocation_length + 1);
        if (output.ptr is null)
            goto fail;
    }

    output_pointer = output.ptr;
    while (input_pointer < input_end)
    {
        if (*input_pointer != '\\')
        {
            *output_pointer++ = *input_pointer++;
        }
        else
        {
            ubyte sequence_length = 2;
            if ((input_end - input_pointer) < 1)
                goto fail;

            switch (input_pointer[1])
            {
            case 'b':
                *output_pointer++ = '\b';
                break;
            case 'f':
                *output_pointer++ = '\f';
                break;
            case 'n':
                *output_pointer++ = '\n';
                break;
            case 'r':
                *output_pointer++ = '\r';
                break;
            case 't':
                *output_pointer++ = '\t';
                break;
            case '"':
            case '\\':
            case '/':
                *output_pointer++ = input_pointer[1];
                break;
            case 'u':
                sequence_length = utf16_literal_to_utf8(input_pointer, input_end, output_pointer);
                if (sequence_length == 0)
                    goto fail;
                break;
            default:
                goto fail;
            }
            input_pointer += sequence_length;
        }
    }

    *output_pointer = '\0';

    item_.type = JsonString;
    item_.value_string = output.ptr;

    input_buffer.offset = cast(size_t)(input_end - input_buffer.content);
    input_buffer.offset++;

    return true;

fail:
    return false;
}

private bool add_item_to_array_impl(JsonNode* array, JsonNode* item_)
{
    if (item_ is null || array is null || array == item_)
        return false;

    auto child = array.child;
    if (child is null)
    {
        array.child = item_;
        item_.prev = item_;
        item_.next = null;
    }
    else
    {
        if (child.prev)
        {
            suffix_object(child.prev, item_);
            array.child.prev = item_;
        }
    }

    return true;
}

private bool add_item_to_object_impl(Allocator alloc, JsonNode* object, const(char)* str, JsonNode* item_, bool constant_key)
{
    char* new_key = null;
    int new_type = JsonInvalid;

    if (object is null || str is null || item_ is null || object == item_)
        return false;

    if (constant_key)
    {
        new_key = cast(char*)str;
        new_type = item_.type | JsonStringIsConst;
    }
    else
    {
        new_key = json_strdup(alloc, str);
        if (new_key is null)
            return false;
        new_type = item_.type & ~JsonStringIsConst;
    }

    item_.key = new_key;
    item_.type = new_type;

    return add_item_to_array_impl(object, item_);
}

private JsonNode* get_array_item_impl(JsonNode* array, size_t index)
{
    if (array is null)
        return null;

    auto current_child = array.child;
    while ((current_child !is null) && (index > 0))
    {
        index--;
        current_child = current_child.next;
    }
    return current_child;
}

private JsonNode* get_object_item_impl(JsonNode* object, const(char)* name, bool case_sensitive)
{
    if (object is null || name is null)
        return null;

    auto current_element = object.child;
    if (case_sensitive)
    {
        while ((current_element !is null) && (current_element.key !is null) && (strcmp(name, current_element.key) != 0))
            current_element = current_element.next;
    }
    else
    {
        while ((current_element !is null) && (cstrcmp_nocase(name, current_element.key) != 0))
            current_element = current_element.next;
    }

    if (current_element is null || current_element.key is null)
        return null;

    return current_element;
}

private bool parse_value(JsonNode* item_, ParseBuffer* input_buffer)
{
    if (input_buffer is null || input_buffer.content is null)
        return false;

    if (can_read(input_buffer, 4) && (strncmp(buffer_at_offset(input_buffer), "null", 4) == 0))
    {
        item_.type = JsonNull;
        input_buffer.offset += 4;
        return true;
    }
    if (can_read(input_buffer, 5) && (strncmp(buffer_at_offset(input_buffer), "false", 5) == 0))
    {
        item_.type = JsonFalse;
        input_buffer.offset += 5;
        return true;
    }
    if (can_read(input_buffer, 4) && (strncmp(buffer_at_offset(input_buffer), "true", 4) == 0))
    {
        item_.type = JsonTrue;
        item_.value_integer = 1;
        input_buffer.offset += 4;
        return true;
    }
    if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == '"'))
        return parse_string(item_, input_buffer);

    if (can_access_at_index(input_buffer, 0))
    {
        auto c = buffer_at_offset(input_buffer)[0];
        if (c == '-' || (c >= '0' && c <= '9'))
            return parse_number(item_, input_buffer);
    }
    if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == '['))
        return parse_array(item_, input_buffer);

    if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == '{'))
        return parse_object(item_, input_buffer);

    return false;
}

private bool parse_array(JsonNode* item_, ParseBuffer* input_buffer)
{
    JsonNode* head = null;
    JsonNode* current_item_ = null;

    if (input_buffer.depth >= NESTING_LIMIT)
        return false;
    input_buffer.depth++;

    if (buffer_at_offset(input_buffer)[0] != '[')
        goto fail;

    input_buffer.offset++;
    buffer_skip_whitespace(input_buffer);
    if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == ']'))
        goto success;

    if (!can_access_at_index(input_buffer, 0))
    {
        input_buffer.offset--;
        goto fail;
    }

    input_buffer.offset--;
    while (true)
    {
        auto new_item_ = new_item(input_buffer.alloc);
        if (new_item_ is null)
            goto fail;

        if (head is null)
            current_item_ = head = new_item_;
        else
        {
            current_item_.next = new_item_;
            new_item_.prev = current_item_;
            current_item_ = new_item_;
        }

        input_buffer.offset++;
        buffer_skip_whitespace(input_buffer);
        if (!parse_value(current_item_, input_buffer))
            goto fail;
        buffer_skip_whitespace(input_buffer);
        if (!can_access_at_index(input_buffer, 0))
            goto fail;

        if (buffer_at_offset(input_buffer)[0] == ']')
            goto success;

        if (buffer_at_offset(input_buffer)[0] != ',')
            goto fail;

        input_buffer.offset++;
        buffer_skip_whitespace(input_buffer);
        if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == ']'))
            goto success;

        if (!can_access_at_index(input_buffer, 0))
            goto fail;

        input_buffer.offset--;
    }

success:
    input_buffer.depth--;

    if (head !is null)
        head.prev = current_item_;

    item_.type = JsonArray;
    item_.child = head;

    input_buffer.offset++;
    return true;

fail:
    return false;
}

private bool parse_object(JsonNode* item_, ParseBuffer* input_buffer)
{
    JsonNode* head = null;
    JsonNode* current_item_ = null;

    if (input_buffer.depth >= NESTING_LIMIT)
        return false;
    input_buffer.depth++;

    if (!can_access_at_index(input_buffer, 0) || (buffer_at_offset(input_buffer)[0] != '{'))
        goto fail;

    input_buffer.offset++;
    buffer_skip_whitespace(input_buffer);
    if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == '}'))
        goto success;

    if (!can_access_at_index(input_buffer, 0))
    {
        input_buffer.offset--;
        goto fail;
    }

    input_buffer.offset--;
    while (true)
    {
        auto new_item_ = new_item(input_buffer.alloc);
        if (new_item_ is null)
            goto fail;

        if (head is null)
            current_item_ = head = new_item_;
        else
        {
            current_item_.next = new_item_;
            new_item_.prev = current_item_;
            current_item_ = new_item_;
        }

        if (!can_access_at_index(input_buffer, 1))
            goto fail;

        input_buffer.offset++;
        buffer_skip_whitespace(input_buffer);
        if (!parse_string(current_item_, input_buffer))
            goto fail;
        buffer_skip_whitespace(input_buffer);

        current_item_.key = current_item_.value_string;
        current_item_.value_string = null;

        if (!can_access_at_index(input_buffer, 0) || (buffer_at_offset(input_buffer)[0] != ':'))
            goto fail;

        input_buffer.offset++;
        buffer_skip_whitespace(input_buffer);
        if (!parse_value(current_item_, input_buffer))
            goto fail;
        buffer_skip_whitespace(input_buffer);
        if (!can_access_at_index(input_buffer, 0))
            goto fail;

        if (buffer_at_offset(input_buffer)[0] == '}')
            goto success;

        if (buffer_at_offset(input_buffer)[0] != ',')
            goto fail;

        input_buffer.offset++;
        buffer_skip_whitespace(input_buffer);
        if (can_access_at_index(input_buffer, 0) && (buffer_at_offset(input_buffer)[0] == '}'))
            goto success;

        if (!can_access_at_index(input_buffer, 0))
            goto fail;

        input_buffer.offset--;
    }

success:
    input_buffer.depth--;

    if (head !is null)
        head.prev = current_item_;

    item_.type = JsonObject;
    item_.child = head;

    input_buffer.offset++;
    return true;

fail:
    return false;
}

private JsonNode* duplicate_rec(Allocator alloc, JsonNode* item_, size_t depth, bool recurse)
{
    JsonNode* newitem = null;
    JsonNode* child = null;
    JsonNode* next_ = null;
    JsonNode* newchild = null;

    if (!item_)
        return null;

    newitem = new_item(alloc);
    if (!newitem)
        return null;

    newitem.type = item_.type & (~JsonIsReference);
    newitem.value_integer = item_.value_integer;
    newitem.value_number = item_.value_number;
    if (item_.value_string)
    {
        newitem.value_string = json_strdup(alloc, item_.value_string);
        if (!newitem.value_string)
            return null;
    }
    if (item_.key)
    {
        newitem.key = (item_.type & JsonStringIsConst) ? item_.key : json_strdup(alloc, item_.key);
        if (!newitem.key)
            return null;
    }

    if (!recurse)
        return newitem;

    child = item_.child;
    while (child !is null)
    {
        if (depth >= CIRCULAR_LIMIT)
            return null;
        newchild = duplicate_rec(alloc, child, depth + 1, true);
        if (!newchild)
            return null;
        if (next_ !is null)
        {
            next_.next = newchild;
            newchild.prev = next_;
            next_ = newchild;
        }
        else
        {
            newitem.child = newchild;
            next_ = newchild;
        }
        child = child.next;
    }
    if (newitem && newitem.child)
        newitem.child.prev = newchild;

    return newitem;
}

struct Json
{
    Allocator alloc;

    static Json create(Allocator allocator)
    {
        Json j;
        j.alloc = allocator;
        return j;
    }

    JsonNode* parse(const(char)[] buffer)
    {
        return parse_with_opts(buffer.ptr, buffer.length, null, false);
    }

    JsonNode* parse_with_opts(const(char)* value, size_t buffer_length, const(char)** return_parse_end, bool require_null_terminated)
    {
        JsonNode* item_ = null;
        ParseBuffer buf;
        memset(&buf, 0, ParseBuffer.sizeof);

        global_error_json = null;
        global_error_pos = 0;

        if (value is null || 0 == buffer_length)
            goto fail;

        buf.content = value;
        buf.length = buffer_length;
        buf.offset = 0;
        buf.alloc = alloc;

        item_ = new_item(alloc);
        if (item_ is null)
            goto fail;

        if (!parse_value(item_, buffer_skip_whitespace(skip_utf8_bom(&buf))))
            goto fail;

        if (require_null_terminated)
        {
            buffer_skip_whitespace(&buf);
            if ((buf.offset >= buf.length) || buffer_at_offset(&buf)[0] != '\0')
                goto fail;
        }
        if (return_parse_end)
            *return_parse_end = buffer_at_offset(&buf);

        return item_;

    fail:
        if (value !is null)
        {
            global_error_json = value;
            global_error_pos = 0;

            if (buf.offset < buf.length)
                global_error_pos = buf.offset;
            else if (buf.length > 0)
                global_error_pos = buf.length - 1;

            if (return_parse_end !is null)
                *return_parse_end = global_error_json + global_error_pos;
        }

        return null;
    }

    int get_array_size(JsonNode* array)
    {
        if (array is null)
            return 0;

        auto child = array.child;
        size_t size = 0;
        while (child !is null)
        {
            size++;
            child = child.next;
        }
        return cast(int)size;
    }

    JsonNode* get_array_item(JsonNode* array, int index)
    {
        if (index < 0)
            return null;
        return get_array_item_impl(array, cast(size_t)index);
    }

    JsonNode* get_object_item(JsonNode* object, const(char)* name)
    {
        return get_object_item_impl(object, name, false);
    }

    JsonNode* get_object_item_case_sensitive(JsonNode* object, const(char)* name)
    {
        return get_object_item_impl(object, name, true);
    }

    bool has_object_item(JsonNode* object, const(char)* name)
    {
        return get_object_item_impl(object, name, false) !is null;
    }

    char* get_string(JsonNode* item_)
    {
        assert(is_string(item_));
        return item_.value_string;
    }

    double get_number(JsonNode* item_)
    {
        assert(is_number(item_));
        return item_.value_number;
    }

    int get_integer(JsonNode* item_)
    {
        assert(is_integer(item_));
        return item_.value_integer;
    }

    bool is_invalid(JsonNode* item_) { assert(item_ != null); return (item_.type & 0xFF) == JsonInvalid; }
    bool is_false(JsonNode* item_)   { assert(item_ != null); return (item_.type & 0xFF) == JsonFalse; }
    bool is_true(JsonNode* item_)    { assert(item_ != null); return (item_.type & 0xFF) == JsonTrue; }
    bool is_bool(JsonNode* item_)    { assert(item_ != null); return (item_.type & (JsonTrue | JsonFalse)) != 0; }
    bool is_null(JsonNode* item_)    { assert(item_ != null); return (item_.type & 0xFF) == JsonNull; }
    bool is_number(JsonNode* item_)  { assert(item_ != null); return (item_.type & 0xFF) == JsonNumber; }
    bool is_integer(JsonNode* item_) { assert(item_ != null); return (item_.type & 0xFF) == JsonNumber; }
    bool is_string(JsonNode* item_)  { assert(item_ != null); return (item_.type & 0xFF) == JsonString; }
    bool is_array(JsonNode* item_)   { assert(item_ != null); return (item_.type & 0xFF) == JsonArray; }
    bool is_object(JsonNode* item_)  { assert(item_ != null); return (item_.type & 0xFF) == JsonObject; }
    bool is_raw(JsonNode* item_)     { assert(item_ != null); return (item_.type & 0xFF) == JsonRaw; }

    JsonNode* create_null()
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = JsonNull;
        return item_;
    }

    JsonNode* create_true()
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = JsonTrue;
        return item_;
    }

    JsonNode* create_false()
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = JsonFalse;
        return item_;
    }

    JsonNode* create_bool(bool boolean)
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = boolean ? JsonTrue : JsonFalse;
        return item_;
    }

    JsonNode* create_number(double num)
    {
        auto item_ = new_item(alloc);
        if (item_)
        {
            item_.type = JsonNumber;
            item_.value_number = num;

            if (num >= int.max)
                item_.value_integer = int.max;
            else if (num <= cast(double)int.min)
                item_.value_integer = int.min;
            else
                item_.value_integer = cast(int)num;
        }
        return item_;
    }

    JsonNode* create_string(const(char)* str)
    {
        auto item_ = new_item(alloc);
        if (item_)
        {
            item_.type = JsonString;
            item_.value_string = json_strdup(alloc, str);
            if (!item_.value_string)
                return null;
        }
        return item_;
    }

    JsonNode* create_string_reference(const(char)* str)
    {
        auto item_ = new_item(alloc);
        if (item_ !is null)
        {
            item_.type = JsonString | JsonIsReference;
            item_.value_string = cast(char*)str;
        }
        return item_;
    }

    JsonNode* create_object_reference(JsonNode* child)
    {
        auto item_ = new_item(alloc);
        if (item_ !is null)
        {
            item_.type = JsonObject | JsonIsReference;
            item_.child = child;
        }
        return item_;
    }

    JsonNode* create_array_reference(JsonNode* child)
    {
        auto item_ = new_item(alloc);
        if (item_ !is null)
        {
            item_.type = JsonArray | JsonIsReference;
            item_.child = child;
        }
        return item_;
    }

    JsonNode* create_raw(const(char)* raw)
    {
        auto item_ = new_item(alloc);
        if (item_)
        {
            item_.type = JsonRaw;
            item_.value_string = json_strdup(alloc, raw);
            if (!item_.value_string)
                return null;
        }
        return item_;
    }

    JsonNode* create_array()
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = JsonArray;
        return item_;
    }

    JsonNode* create_object()
    {
        auto item_ = new_item(alloc);
        if (item_)
            item_.type = JsonObject;
        return item_;
    }

    JsonNode* create_int_array(const(int)* numbers, int count)
    {
        if (count < 0 || numbers is null)
            return null;

        auto a = create_array();
        JsonNode* n = null;
        JsonNode* p = null;

        for (size_t i = 0; a && (i < cast(size_t)count); i++)
        {
            n = create_number(cast(double)numbers[i]);
            if (!n) return null;
            if (!i)
                a.child = n;
            else
                suffix_object(p, n);
            p = n;
        }

        if (a && a.child)
            a.child.prev = n;

        return a;
    }

    JsonNode* create_float_array(const(float)* numbers, int count)
    {
        if (count < 0 || numbers is null)
            return null;

        auto a = create_array();
        JsonNode* n = null;
        JsonNode* p = null;

        for (size_t i = 0; a && (i < cast(size_t)count); i++)
        {
            n = create_number(cast(double)numbers[i]);
            if (!n) return null;
            if (!i)
                a.child = n;
            else
                suffix_object(p, n);
            p = n;
        }

        if (a && a.child)
            a.child.prev = n;

        return a;
    }

    JsonNode* create_double_array(const(double)* numbers, int count)
    {
        if (count < 0 || numbers is null)
            return null;

        auto a = create_array();
        JsonNode* n = null;
        JsonNode* p = null;

        for (size_t i = 0; a && (i < cast(size_t)count); i++)
        {
            n = create_number(numbers[i]);
            if (!n) return null;
            if (!i)
                a.child = n;
            else
                suffix_object(p, n);
            p = n;
        }

        if (a && a.child)
            a.child.prev = n;

        return a;
    }

    JsonNode* create_string_array(const(char*)* strings, int count)
    {
        if (count < 0 || strings is null)
            return null;

        auto a = create_array();
        JsonNode* n = null;
        JsonNode* p = null;

        for (size_t i = 0; a && (i < cast(size_t)count); i++)
        {
            n = create_string(strings[i]);
            if (!n) return null;
            if (!i)
                a.child = n;
            else
                suffix_object(p, n);
            p = n;
        }

        if (a && a.child)
            a.child.prev = n;

        return a;
    }

    bool add_item_to_array(JsonNode* array, JsonNode* item_)
    {
        return add_item_to_array_impl(array, item_);
    }

    bool add_item_to_object(JsonNode* object, const(char)* str, JsonNode* item_)
    {
        return add_item_to_object_impl(alloc, object, str, item_, false);
    }

    bool add_item_to_object_cs(JsonNode* object, const(char)* str, JsonNode* item_)
    {
        return add_item_to_object_impl(alloc, object, str, item_, true);
    }

    bool add_item_reference_to_array(JsonNode* array, JsonNode* item_)
    {
        if (array is null)
            return false;
        return add_item_to_array_impl(array, create_reference(item_, alloc));
    }

    bool add_item_reference_to_object(JsonNode* object, const(char)* str, JsonNode* item_)
    {
        if (object is null || str is null)
            return false;
        return add_item_to_object_impl(alloc, object, str, create_reference(item_, alloc), false);
    }

    JsonNode* detach_item_via_pointer(JsonNode* parent, JsonNode* item_)
    {
        if (parent is null || item_ is null || (item_ != parent.child && item_.prev is null))
            return null;

        if (item_ != parent.child)
            item_.prev.next = item_.next;
        if (item_.next !is null)
            item_.next.prev = item_.prev;

        if (item_ == parent.child)
            parent.child = item_.next;
        else if (item_.next is null)
            parent.child.prev = item_.prev;

        item_.prev = null;
        item_.next = null;

        return item_;
    }

    JsonNode* detach_item_from_array(JsonNode* array, int which)
    {
        if (which < 0)
            return null;
        return detach_item_via_pointer(array, get_array_item_impl(array, cast(size_t)which));
    }

    JsonNode* detach_item_from_object(JsonNode* object, const(char)* str)
    {
        return detach_item_via_pointer(object, get_object_item_impl(object, str, false));
    }

    JsonNode* detach_item_from_object_case_sensitive(JsonNode* object, const(char)* str)
    {
        return detach_item_via_pointer(object, get_object_item_impl(object, str, true));
    }

    bool insert_item_in_array(JsonNode* array, int which, JsonNode* newitem)
    {
        if (which < 0 || newitem is null)
            return false;

        auto after_inserted = get_array_item_impl(array, cast(size_t)which);
        if (after_inserted is null)
            return add_item_to_array_impl(array, newitem);

        if (after_inserted != array.child && after_inserted.prev is null)
            return false;

        newitem.next = after_inserted;
        newitem.prev = after_inserted.prev;
        after_inserted.prev = newitem;
        if (after_inserted == array.child)
            array.child = newitem;
        else
            newitem.prev.next = newitem;

        return true;
    }

    bool replace_item_via_pointer(JsonNode* parent, JsonNode* item_, JsonNode* replacement)
    {
        if (parent is null || parent.child is null || replacement is null || item_ is null)
            return false;

        if (replacement == item_)
            return true;

        replacement.next = item_.next;
        replacement.prev = item_.prev;

        if (replacement.next !is null)
            replacement.next.prev = replacement;
        if (parent.child == item_)
        {
            if (parent.child.prev == parent.child)
                replacement.prev = replacement;
            parent.child = replacement;
        }
        else
        {
            if (replacement.prev !is null)
                replacement.prev.next = replacement;
            if (replacement.next is null)
                parent.child.prev = replacement;
        }

        item_.next = null;
        item_.prev = null;

        return true;
    }

    bool replace_item_in_array(JsonNode* array, int which, JsonNode* newitem)
    {
        if (which < 0 || newitem is null)
            return false;
        return replace_item_via_pointer(array, get_array_item_impl(array, cast(size_t)which), newitem);
    }

    bool replace_item_in_object(JsonNode* object, const(char)* str, JsonNode* newitem)
    {
        return replace_item_in_object_impl(object, str, newitem, false);
    }

    bool replace_item_in_object_case_sensitive(JsonNode* object, const(char)* str, JsonNode* newitem)
    {
        return replace_item_in_object_impl(object, str, newitem, true);
    }

    private bool replace_item_in_object_impl(JsonNode* object, const(char)* str, JsonNode* replacement, bool case_sensitive)
    {
        if (replacement is null || str is null)
            return false;

        replacement.key = json_strdup(alloc, str);
        if (replacement.key is null)
            return false;

        replacement.type &= ~JsonStringIsConst;

        return replace_item_via_pointer(object, get_object_item_impl(object, str, case_sensitive), replacement);
    }

    JsonNode* add_null_to_object(JsonNode* object, const(char)* name)
    {
        auto n = create_null();
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_true_to_object(JsonNode* object, const(char)* name)
    {
        auto n = create_true();
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_false_to_object(JsonNode* object, const(char)* name)
    {
        auto n = create_false();
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_bool_to_object(JsonNode* object, const(char)* name, bool boolean)
    {
        auto n = create_bool(boolean);
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_number_to_object(JsonNode* object, const(char)* name, double number)
    {
        auto n = create_number(number);
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_string_to_object(JsonNode* object, const(char)* name, const(char)* str)
    {
        auto n = create_string(str);
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_raw_to_object(JsonNode* object, const(char)* name, const(char)* raw)
    {
        auto n = create_raw(raw);
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_object_to_object(JsonNode* object, const(char)* name)
    {
        auto n = create_object();
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* add_array_to_object(JsonNode* object, const(char)* name)
    {
        auto n = create_array();
        if (add_item_to_object_impl(alloc, object, name, n, false))
            return n;
        return null;
    }

    JsonNode* duplicate(JsonNode* item_, bool recurse)
    {
        return duplicate_rec(alloc, item_, 0, recurse);
    }

    bool compare(JsonNode* a, JsonNode* b, bool case_sensitive)
    {
        if (a is null || b is null || ((a.type & 0xFF) != (b.type & 0xFF)))
            return false;

        switch (a.type & 0xFF)
        {
        case JsonFalse:
        case JsonTrue:
        case JsonNull:
        case JsonNumber:
        case JsonString:
        case JsonRaw:
        case JsonArray:
        case JsonObject:
            break;
        default:
            return false;
        }

        if (a == b)
            return true;

        switch (a.type & 0xFF)
        {
        case JsonFalse:
        case JsonTrue:
        case JsonNull:
            return true;

        case JsonNumber:
            return compare_double(a.value_number, b.value_number);

        case JsonString:
        case JsonRaw:
            if (a.value_string is null || b.value_string is null)
                return false;
            return strcmp(a.value_string, b.value_string) == 0;

        case JsonArray:
        {
            auto a_el = a.child;
            auto b_el = b.child;
            for (; (a_el !is null) && (b_el !is null);)
            {
                if (!compare(a_el, b_el, case_sensitive))
                    return false;
                a_el = a_el.next;
                b_el = b_el.next;
            }
            return a_el == b_el;
        }

        case JsonObject:
        {
            auto a_el = a.child;
            while (a_el)
            {
                auto b_el = get_object_item_impl(b, a_el.key, case_sensitive);
                if (b_el is null)
                    return false;
                if (!compare(a_el, b_el, case_sensitive))
                    return false;
                a_el = a_el.next;
            }

            auto b_el = b.child;
            while (b_el)
            {
                auto a_el2 = get_object_item_impl(a, b_el.key, case_sensitive);
                if (a_el2 is null)
                    return false;
                if (!compare(b_el, a_el2, case_sensitive))
                    return false;
                b_el = b_el.next;
            }
            return true;
        }

        default:
            return false;
        }
    }

    double set_number_helper(JsonNode* item_, double number)
    {
        if (item_ is null)
            return 0.0 / 0.0;

        if (number >= int.max)
            item_.value_integer = int.max;
        else if (number <= cast(double)int.min)
            item_.value_integer = int.min;
        else
            item_.value_integer = cast(int)number;

        return item_.value_number = number;
    }

    char* set_value_string(JsonNode* object, const(char)* value_string)
    {
        if (object is null || !(object.type & JsonString) || (object.type & JsonIsReference))
            return null;
        if (object.value_string is null || value_string is null)
            return null;

        auto v1_len = strlen(value_string);
        auto v2_len = strlen(object.value_string);

        if (v1_len <= v2_len)
        {
            if (!(value_string + v1_len < object.value_string || object.value_string + v2_len < value_string))
                return null;
            strcpy(object.value_string, value_string);
            return object.value_string;
        }

        auto copy = json_strdup(alloc, value_string);
        if (copy is null)
            return null;
        object.value_string = copy;

        return copy;
    }

    bool copy_string_from(JsonNode* object, const(char)* field_name, char[] dst)
    {
        auto item = get_object_item(object, field_name);
        auto text = get_string(item);
        if (text is null) return false;
        auto len = strlen(text);
        if (len + 1 > dst.length) return false;
        if (len > 0)
            memcpy(dst.ptr, text, len);
        dst[len] = '\0';
        return true;
    }

    bool read_uint(JsonNode* object, const(char)* field_name, out uint value)
    {
        value = 0;
        auto item = get_object_item(object, field_name);
        if (!is_number(item)) return false;
        value = cast(uint)item.value_integer;
        return true;
    }

    bool read_float(JsonNode* object, const(char)* field_name, out float value)
    {
        value = 0;
        auto item = get_object_item(object, field_name);
        if (!is_number(item)) return false;
        value = cast(float)item.value_number;
        return true;
    }

    bool read_bool(JsonNode* object, const(char)* field_name, out bool value)
    {
        value = false;
        auto item = get_object_item(object, field_name);
        if (is_true(item))
        {
            value = true;
            return true;
        }
        if (is_false(item))
        {
            value = false;
            return true;
        }
        return false;
    }
}

// ---------- serializer (new; kdom keeps this in a separate file) ----------
// Prints canonical JSON. Strings must be NUL-terminated (guaranteed for
// parser-decoded strings and arena-dup'd builder strings).
struct JsonPrinter
{
    char[] buf;
}

private void printEscaped(ref JsonPrinter p, const(char)* s)
{
    static immutable char[] hex = "0123456789abcdef";
    p.buf ~= '"';
    if (!s)
    {
        p.buf ~= '"';
        return;
    }
    for (const(char)* q = s; *q; q++)
    {
        // Plain characters go in runs: one append per run, not per char.
        const(char)* run = q;
        while (*q && *q != '"' && *q != '\\' && cast(ubyte)*q >= 0x20)
            q++;
        if (q > run)
            p.buf ~= run[0 .. q - run];
        if (!*q)
            break;
        char c = *q;
        switch (c)
        {
        case '"':  p.buf ~= "\\\""; break;
        case '\\': p.buf ~= "\\\\"; break;
        case '\b': p.buf ~= "\\b"; break;
        case '\f': p.buf ~= "\\f"; break;
        case '\n': p.buf ~= "\\n"; break;
        case '\r': p.buf ~= "\\r"; break;
        case '\t': p.buf ~= "\\t"; break;
        default:
            if (cast(ubyte)c < 0x20)
            {
                p.buf ~= "\\u00";
                p.buf ~= hex[(c >> 4) & 0xF];
                p.buf ~= hex[c & 0xF];
            }
            else
                p.buf ~= c;
            break;
        }
    }
    p.buf ~= '"';
}

private void printInt(ref JsonPrinter p, long v)
{
    char[24] tmp;
    size_t n = 0;
    bool neg = v < 0;
    ulong u = neg ? cast(ulong)(-(v + 1)) + 1 : cast(ulong)v;
    do
    {
        tmp[n++] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u > 0 && n < tmp.length);
    if (neg)
        p.buf ~= '-';
    while (n > 0)
        p.buf ~= tmp[--n];
}

void printJson(ref JsonPrinter p, JsonNode* n)
{
    if (n is null)
    {
        p.buf ~= "null";
        return;
    }
    switch (n.type & 0xFF)
    {
    case JsonNull:
        p.buf ~= "null";
        break;
    case JsonFalse:
        p.buf ~= "false";
        break;
    case JsonTrue:
        p.buf ~= "true";
        break;
    case JsonNumber:
        if (n.value_number == cast(double)n.value_integer)
            printInt(p, n.value_integer);
        else
        {
            char[64] tmp;
            auto k = snprintf(tmp.ptr, tmp.length, "%g", n.value_number);
            if (k <= 0 || cast(size_t)k >= tmp.length)
                p.buf ~= "0";
            else
                p.buf ~= tmp[0 .. k];
        }
        break;
    case JsonString:
        printEscaped(p, n.value_string);
        break;
    case JsonRaw:
        if (n.value_string)
            p.buf ~= n.value_string[0 .. strlen(n.value_string)];
        break;
    case JsonArray:
    {
        p.buf ~= '[';
        bool first = true;
        for (auto c = n.child; c; c = c.next)
        {
            if (!first)
                p.buf ~= ',';
            first = false;
            printJson(p, c);
        }
        p.buf ~= ']';
        break;
    }
    case JsonObject:
    {
        p.buf ~= '{';
        bool first = true;
        for (auto c = n.child; c; c = c.next)
        {
            if (!first)
                p.buf ~= ',';
            first = false;
            printEscaped(p, c.key);
            p.buf ~= ':';
            printJson(p, c);
        }
        p.buf ~= '}';
        break;
    }
    default:
        p.buf ~= "null";
        break;
    }
}

// Serialize a tree to a GC string (transient responses).
string printJsonStr(JsonNode* root)
{
    JsonPrinter p;
    printJson(p, root);
    return p.buf.idup;
}
