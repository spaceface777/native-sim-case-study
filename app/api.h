/* SPDX-License-Identifier: Apache-2.0 */
#ifndef APP_API_H
#define APP_API_H
#include <stdint.h>

#define INSTANCES  20
#define WORLD      INSTANCES
#define RPC_IRQ    31
#define BATCH_SIZE 64

#ifdef __APPLE__
#define INSTANCE_SECTION "__DATA,instances"
#define INSTANCE_START   "section$start$__DATA$instances"
#else
#define INSTANCE_SECTION "instances"
#define INSTANCE_START   "__start_instances"
#endif

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

struct instance_api {
	void (*boot)(unsigned id);
	uint64_t (*run)(uint64_t start, uint64_t until, const struct batch* input, struct batch* output);
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
