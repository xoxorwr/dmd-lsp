module u1;

import liba;
import libb;
import liba : bar;

int run(int used, int unused)
{
    return foo(used) + bar(1);
}
