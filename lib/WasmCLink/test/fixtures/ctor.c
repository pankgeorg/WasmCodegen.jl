static volatile double x;
__attribute__((constructor)) static void init(void) { x = x + 1.0; }
double ctor_f(double a) { return a + x; }
