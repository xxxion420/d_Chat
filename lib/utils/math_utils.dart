class MathUtils {
  static double sin(double x) => MathUtils._sine(x);
  static double _sine(double x) {
    const pi = 3.1415926535897932;
    x = x % (2 * pi);
    final x2 = x * x;
    final x3 = x2 * x;
    final x5 = x3 * x2;
    final x7 = x5 * x2;
    final x9 = x7 * x2;
    return x - x3 / 6 + x5 / 120 - x7 / 5040 + x9 / 362880;
  }
}
