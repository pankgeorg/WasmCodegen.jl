extern volatile double constructor_state;
__attribute__((constructor)) static void init(void) { constructor_state = 7.0; }
