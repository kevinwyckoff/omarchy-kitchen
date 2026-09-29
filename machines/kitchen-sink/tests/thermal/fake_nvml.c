/*
 * fake_nvml.c: a stand-in libnvidia-ml.so.1 with only the entry points
 * kitchen-thermald calls, declared exactly as in nvml.h (615.71.09). Built by
 * the tests when a C compiler is present, it checks the daemon's ctypes side
 * against real C: argument widths (a 64-bit event mask, an unsigned timeout),
 * the nvmlEventData_t and nvmlFieldValue_t layouts, and pointer passing.
 *
 * Values are chosen to catch truncation: the supported mask and the reasons
 * carry a bit above 32, the counters are larger than 2^32, and every call is
 * logged to $FAKE_NVML_LOG so the tests see what the daemon passed.
 *
 * Events come from $FAKE_NVML_EVENTS, one "TYPE DATA" line per wait; once the
 * file is used up, a wait sleeps (at most 50 ms) and returns NVML_ERROR_TIMEOUT.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *nvmlDevice_t;
typedef void *nvmlEventSet_t;
typedef int nvmlReturn_t;

typedef struct {
	nvmlDevice_t device;
	unsigned long long eventType;
	unsigned long long eventData;
	unsigned int gpuInstanceId;
	unsigned int computeInstanceId;
} nvmlEventData_t;

typedef union {
	double dVal;
	unsigned int uiVal;
	unsigned long ulVal;
	unsigned long long ullVal;
	signed long long sllVal;
	signed int siVal;
	unsigned short usVal;
} nvmlValue_t;

typedef struct {
	unsigned int fieldId;
	unsigned int scopeId;
	long long timestamp;
	long long latencyUsec;
	int valueType;
	nvmlReturn_t nvmlReturn;
	nvmlValue_t value;
} nvmlFieldValue_t;

#define DEV ((nvmlDevice_t)0x1650)
#define SET ((nvmlEventSet_t)0xe5e7)

static void logit(const char *fmt, ...)
{
	const char *path = getenv("FAKE_NVML_LOG");
	FILE *f;
	va_list ap;

	if (!path || !(f = fopen(path, "a")))
		return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static int wrong_device(nvmlDevice_t d, const char *fn)
{
	if (d == DEV)
		return 0;
	logit("%s: bad device %p", fn, d);
	return 1;
}

nvmlReturn_t nvmlInit_v2(void)
{
	const char *rc = getenv("FAKE_NVML_INIT_RC");

	logit("init");
	return rc ? atoi(rc) : 0;
}

nvmlReturn_t nvmlShutdown(void)
{
	logit("shutdown");
	return 0;
}

const char *nvmlErrorString(nvmlReturn_t rc)
{
	static char buf[32];

	snprintf(buf, sizeof(buf), "fake error %d", rc);
	return buf;
}

nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t *device)
{
	logit("handle %u", index);
	*device = DEV;
	return 0;
}

nvmlReturn_t nvmlDeviceGetSupportedEventTypes(nvmlDevice_t device, unsigned long long *eventTypes)
{
	if (wrong_device(device, "supported"))
		return 2;
	*eventTypes = 0xc19cULL | (1ULL << 40);
	return 0;
}

nvmlReturn_t nvmlEventSetCreate(nvmlEventSet_t *set)
{
	*set = SET;
	return 0;
}

nvmlReturn_t nvmlDeviceRegisterEvents(nvmlDevice_t device, unsigned long long eventTypes, nvmlEventSet_t set)
{
	logit("register %p 0x%llx %p", device, eventTypes, set);
	return wrong_device(device, "register") || set != SET ? 2 : 0;
}

nvmlReturn_t nvmlEventSetWait_v2(nvmlEventSet_t set, nvmlEventData_t *data, unsigned int timeoutms)
{
	static int line;
	static char last[512];
	const char *path = getenv("FAKE_NVML_EVENTS");
	char buf[128];
	int n = 0;
	FILE *f;

	logit("wait %u", timeoutms);
	if (set != SET)
		return 2;
	/* each events file is played from its first line */
	if (path && strcmp(path, last)) {
		snprintf(last, sizeof(last), "%s", path);
		line = 0;
	}
	if (path && (f = fopen(path, "r"))) {
		while (fgets(buf, sizeof(buf), f)) {
			unsigned long long type, value;

			if (n++ != line || sscanf(buf, "%llu %llu", &type, &value) != 2)
				continue;
			fclose(f);
			line++;
			memset(data, 0, sizeof(*data));
			data->device = DEV;
			data->eventType = type;
			data->eventData = value;
			data->gpuInstanceId = 0xffffffffu;
			data->computeInstanceId = 0xffffffffu;
			return 0;
		}
		fclose(f);
	}
	usleep((timeoutms < 50 ? timeoutms : 50) * 1000);
	return 10; /* NVML_ERROR_TIMEOUT */
}

nvmlReturn_t nvmlEventSetFree(nvmlEventSet_t set)
{
	logit("free %p", set);
	return 0;
}

nvmlReturn_t nvmlDeviceGetTemperature(nvmlDevice_t device, int sensorType, unsigned int *temp)
{
	if (wrong_device(device, "temperature") || sensorType != 0)
		return 2;
	*temp = 47;
	return 0;
}

nvmlReturn_t nvmlDeviceGetPerformanceState(nvmlDevice_t device, int *pState)
{
	if (wrong_device(device, "pstate"))
		return 2;
	*pState = 2;
	return 0;
}

nvmlReturn_t nvmlDeviceGetFieldValues(nvmlDevice_t device, int valuesCount, nvmlFieldValue_t *values)
{
	static unsigned long long calls;
	int i;

	if (wrong_device(device, "fields"))
		return 2;
	calls++;
	logit("fields %d %u %u %u", valuesCount, values[0].fieldId, valuesCount > 1 ? values[1].fieldId : 0,
	      valuesCount > 2 ? values[2].fieldId : 0);
	for (i = 0; i < valuesCount; i++) {
		values[i].valueType = 3; /* unsigned long long */
		values[i].nvmlReturn = 0;
		/* sw-thermal (269) moves on every call after the first */
		values[i].value.ullVal = values[i].fieldId * 10000000000ULL + (values[i].fieldId == 269 ? calls : 0);
	}
	return 0;
}

nvmlReturn_t nvmlDeviceGetCurrentClocksEventReasons(nvmlDevice_t device, unsigned long long *reasons)
{
	logit("reasons");
	if (wrong_device(device, "reasons"))
		return 2;
	*reasons = 0x20ULL | (1ULL << 33);
	return 0;
}
