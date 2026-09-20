int g_add = 7;

int addmul(int a, int b, int c)
{
    return a * b + c;
}

int sumto(int n)
{
    int s = 0;
    int i = 1;
    while (i <= n) {
        s = s + i;
        i = i + 1;
    }
    return s;
}

int divrem(int a, int b)
{
    int q = a / b;
    int r = a % b;
    return q * 1000 + r;
}

int run_div(int a, int b)
{
    return divrem(a, b);
}

int pick(int c)
{
    if (c == 1)
        return 10;
    if (c == 2)
        return 20;
    return c;
}

int main(void)
{
    int r;
    r = addmul(g_add, 3, 2);      /* 23  */
    r = r + sumto(10);            /* 78  */
    r = r + run_div(7, 3);        /* 2079 */
    r = r + pick(2);              /* 2099 = 0x833 */
    return r;
}