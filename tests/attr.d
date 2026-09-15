module attr;

mixin template Helper()
{
    int helperField;
}

struct Widget
{
private:
    int hidden;
    mixin Helper!();
public:
    int shown;
    void greet() {}
}

void f(Widget w)
{
    auto q = w.sh;
    w.
}
