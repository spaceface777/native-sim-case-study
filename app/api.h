/* SPDX-License-Identifier: Apache-2.0 */
#ifndef APP_API_H
#define APP_API_H
#include <stdint.h>

#define INSTANCES  20
#define WORLD      INSTANCES
#define RPC_IRQ    31
#define BATCH_SIZE 64

/* Each instance image contributes one table to this section. The final link collects them,
 * in link order, into one array bounded by __start_instances/__stop_instances. */
#define INSTANCE_SECTION "instances"

enum message_type { HEARTBEAT, EVENT, ACK };

struct message {
	unsigned          source, destination;
	enum message_type type;
	uint64_t          value;
};

struct batch {
	unsigned       count;
	struct message messages[BATCH_SIZE];
};

/* Generic control of one device (firmware + private runner), provided by app/runner.c. */
struct instance_api {
	/* Configure the firmware for device `id`, then boot it until its CPU first idles. */
	void (*boot)(unsigned id);
	/* The device's simulated time, in microseconds. */
	uint64_t (*now)(void);
	/* Run every hardware event up to and including `until`. Return the next event time. */
	uint64_t (*advance)(uint64_t until);
	/* Mailbox the firmware reads from and writes to during the following advances. */
	void (*attach)(const struct batch* input, struct batch* output);
	/* Raise an interrupt line of the device's interrupt controller. */
	void (*interrupt)(unsigned irq);
	/* Application-specific result. */
	uint64_t (*state)(void);
};

static inline unsigned random_between(uint32_t* state, unsigned min, unsigned max) {
	*state ^= *state << 13;
	*state ^= *state >> 17;
	*state ^= *state << 5;
	return min + *state % (max - min + 1);
}

/* Private firmware/runner interface, resolved before localization. */
void     app_configure(unsigned id);
uint64_t app_state(void);
int      runner_receive(struct message* message);
void     runner_send(struct message message);
#endif
