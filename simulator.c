/* SPDX-License-Identifier: Apache-2.0 */
#include "app/api.h"
#include <inttypes.h>
#include <stdio.h>

/* Linker-generated bounds of the instance tables, one per linked instance image. */
extern const struct instance_api instances[INSTANCES] __asm("__start_" INSTANCE_SECTION);
extern const struct instance_api instances_end[] __asm("__stop_" INSTANCE_SECTION);
/* Eleven slots hold deliveries delayed by one through ten world ticks. */
static struct batch deliveries[11][INSTANCES + 1], outputs[INSTANCES];
static uint64_t     next_wake[INSTANCES], last_heartbeat[INSTANCES];
static uint32_t     random_state = 1;
/* FNV-1a hash over every message and its delivery tick, in acceptance order. */
static uint64_t trace_hash = 0xcbf29ce484222325u, trace_count;

static void trace(uint64_t value) {
	for (unsigned i = 0; i < 8; i++, value >>= 8) trace_hash = (trace_hash ^ (value & 0xff)) * 0x100000001b3u;
}

static void step(uint64_t start, uint64_t until) {
	struct batch* inputs = deliveries[(start / 1000) % 11];
	for (unsigned j = 0; j < inputs[WORLD].count; j++) {
		struct message message         = inputs[WORLD].messages[j];
		last_heartbeat[message.source] = message.value;
	}
	for (unsigned i = 0; i < INSTANCES; i++) {
		outputs[i].count = 0;
		if (!inputs[i].count && next_wake[i] > until) continue; /* Idle: skip it */
		const struct instance_api* device = &instances[i];
		/* Catch up omitted, event-free time before making new input visible. */
		if (device->now() < start) device->advance(start);
		device->attach(&inputs[i], &outputs[i]);
		if (inputs[i].count) device->interrupt(RPC_IRQ);
		next_wake[i] = device->advance(until);
	}

	/* Accept send requests only after all grants finish. */
	for (unsigned i = 0; i <= WORLD; i++) inputs[i].count = 0;
	for (unsigned i = 0; i < INSTANCES; i++) {
		for (unsigned j = 0; j < outputs[i].count; j++) {
			struct message message                      = outputs[i].messages[j];
			uint64_t       tick                         = until / 1000 + random_between(&random_state, 1, 10);
			struct batch*  destination                  = &deliveries[tick % 11][message.destination];
			destination->messages[destination->count++] = message;
			trace(tick);
			trace(message.source);
			trace(message.destination);
			trace(message.type);
			trace(message.value);
			trace_count++;
		}
	}
}

int main(void) {
	uint64_t end_us = 3600000000; /* One simulated hour */
	if (instances_end - instances != INSTANCES) {
		fprintf(stderr, "linked %td instances, expected %d\n", instances_end - instances, INSTANCES);
		return 1;
	}
	for (unsigned i = 0; i < INSTANCES; i++) instances[i].boot(i);
	for (uint64_t time = 1000; time <= end_us; time += 1000) step(time - 1000, time);
	step(end_us, end_us); /* Deliver packets due exactly at the endpoint. */
	/* Per device: acknowledged events, and its last heartbeat seen by the world. */
	for (unsigned i = 0; i < INSTANCES; i++)
		printf("%" PRIu64 " %" PRIu64 "\n", instances[i].state(), last_heartbeat[i]);
	printf("trace %016" PRIx64 " %" PRIu64 "\n", trace_hash, trace_count);
	return 0;
}
