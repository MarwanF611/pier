#ifndef CSENSORS_H
#define CSENSORS_H

/// Average temperature of the CPU dies in degrees Celsius, or -1 when no sensor answers.
double pier_cpu_temperature(void);

/// Prints every temperature sensor and its reading to stdout. Used by `Pier --sensors`.
void pier_dump_temperature_sensors(void);

#endif
