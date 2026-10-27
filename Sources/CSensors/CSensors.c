#include "CSensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// Private IOHID event system API. These symbols are exported by IOKit and are what
// Activity Monitor-style tools use to read Apple Silicon thermal sensors without root.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kTemperatureField (kIOHIDEventTypeTemperature << 16)
#define kAppleVendorUsagePage 0xff00
#define kAppleVendorTemperatureUsage 5

static IOHIDEventSystemClientRef sharedClient(void) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client) return client;

    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;

    int page = kAppleVendorUsagePage, usage = kAppleVendorTemperatureUsage;
    CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { pageNumber, usageNumber };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(pageNumber);
    CFRelease(usageNumber);
    return client;
}

typedef void (*SensorVisitor)(const char *name, double celsius, void *context);

static void visitSensors(SensorVisitor visit, void *context) {
    IOHIDEventSystemClientRef client = sharedClient();
    if (!client) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return;

    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        char name[128] = "";
        if (product && CFGetTypeID(product) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)product, name, sizeof name, kCFStringEncodingUTF8);
        }
        if (product) CFRelease(product);

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double celsius = IOHIDEventGetFloatValue(event, kTemperatureField);
        CFRelease(event);

        // Disconnected sensors report 0 or absurd values.
        if (celsius > 0 && celsius < 150) visit(name, celsius, context);
    }
    CFRelease(services);
}

typedef struct {
    double dieSum; int dieCount;
    double pmuMax;
} TemperatureAccumulator;

static void accumulate(const char *name, double celsius, void *context) {
    TemperatureAccumulator *acc = context;
    // "PMU tdie*" are the per-cluster CPU die sensors on M1 through M4.
    if (strstr(name, "tdie")) {
        acc->dieSum += celsius;
        acc->dieCount++;
    }
    if (strstr(name, "PMU") && celsius > acc->pmuMax) acc->pmuMax = celsius;
}

double pier_cpu_temperature(void) {
    TemperatureAccumulator acc = { 0, 0, 0 };
    visitSensors(accumulate, &acc);
    if (acc.dieCount > 0) return acc.dieSum / acc.dieCount;
    if (acc.pmuMax > 0) return acc.pmuMax;
    return -1;
}

static void printSensor(const char *name, double celsius, void *context) {
    (void)context;
    printf("%-32s %6.1f °C\n", name, celsius);
}

void pier_dump_temperature_sensors(void) {
    visitSensors(printSensor, NULL);
    printf("CPU average: %.1f °C\n", pier_cpu_temperature());
}
