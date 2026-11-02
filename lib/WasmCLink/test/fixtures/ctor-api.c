volatile double constructor_state;
double ctor_split(double x) { return x + constructor_state; }
