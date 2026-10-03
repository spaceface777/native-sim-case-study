/* SPDX-License-Identifier: Apache-2.0 */
#include "app/api.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

extern const struct instance_api instances[INSTANCES] __asm(INSTANCE_START);
/* Eleven slots hold deliveries delayed by one through ten world ticks. */
static struct batch deliveries[11][INSTANCES + 1], outputs[INSTANCES];
static uint64_t     next_wake[INSTANCES], last_heartbeat[INSTANCES];
static uint32_t     random_state = 1;
/* Reference mode: enter every device on every tick instead of skipping idle ones. */
static int always_tick;
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
		if (always_tick || inputs[i].count || next_wake[i] <= until)
			next_wake[i] = instances[i].run(start, until, &inputs[i], &outputs[i]);
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

int main(int argc, char** argv) {
	uint64_t end_us = argc > 1 ? strtoull(argv[1], NULL, 10) : 60000000;
	always_tick     = argc > 2;
	for (unsigned i = 0; i < INSTANCES; i++) instances[i].boot(i);
	for (uint64_t time = 1000; time <= end_us; time += 1000) step(time - 1000, time);
	step(end_us, end_us); /* Deliver packets due exactly at the endpoint. */
	/* Per device: acknowledged events, and its last heartbeat seen by the world. */
	for (unsigned i = 0; i < INSTANCES; i++)
		printf("%" PRIu64 " %" PRIu64 "\n", instances[i].state(), last_heartbeat[i]);
	printf("trace %016" PRIx64 " %" PRIu64 "\n", trace_hash, trace_count);
	return 0;
}
