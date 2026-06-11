import 'dart:math';

double circularMean(Iterable<double> anglesRad) {
  double sinSum = 0;
  double cosSum = 0;

  for (final angleRad in anglesRad) {
    sinSum += sin(angleRad);
    cosSum += cos(angleRad);
  }

  final count = anglesRad.length;
  return atan2(sinSum / count, cosSum / count);
}
