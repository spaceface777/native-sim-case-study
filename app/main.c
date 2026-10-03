/* SPDX-License-Identifier: Apache-2.0 */
#include "api.h"
#include <nsi_cpu_if.h>
#include <zephyr/irq.h>
#include <zephyr/kernel.h>

static unsigned instance_id;
static uint32_t random_state;
static uint64_t acknowledged;
K_MSGQ_DEFINE(rpc_queue, sizeof(struct message), BATCH_SIZE, 8);

NATIVE_SIMULATOR_IF void app_configure(unsigned id) {
	instance_id  = id;
	random_state = id + 1;
}

NATIVE_SIMULATOR_IF uint64_t app_state(void) {
	return acknowledged;
}

static void send(unsigned destination, enum message_type type, uint64_t value) {
	runner_send((struct message){instance_id, destination, type, value});
}

static void ingress_isr(const void* unused) {
	struct message message;
	while (runner_receive(&message)) k_msgq_put(&rpc_queue, &message, K_NO_WAIT);
}

static void heartbeat_thread(void* a, void* b, void* c) {
	for (uint64_t next = 100;; next += 100) {
		k_sleep(K_TIMEOUT_ABS_MS(next));
		send(WORLD, HEARTBEAT, next);
	}
}

static void work_thread(void* a, void* b, void* c) {
	uint64_t next = 0, sequence = 0;
	for (;;) {
		next += random_between(&random_state, 10, 100);
		k_sleep(K_TIMEOUT_ABS_MS(next));
		sequence++;
		unsigned count    = random_between(&random_state, 1, 5);
		uint32_t selected = 1u << instance_id;
		for (unsigned i = 0; i < count; i++) {
			unsigned destination;
			do {
				destination = random_between(&random_state, 0, INSTANCES - 1);
			} while (selected & (1u << destination));
			selected |= 1u << destination;
			send(destination, EVENT, sequence);
		}
	}
}

static void rpc_thread(void* a, void* b, void* c) {
	for (;;) {
		struct message message;
		k_msgq_get(&rpc_queue, &message, K_FOREVER);
		if (message.type == EVENT) send(message.source, ACK, message.value);
		else if (message.type == ACK) acknowledged++;
	}
}

K_THREAD_DEFINE(heartbeat_tid, 2048, heartbeat_thread, NULL, NULL, NULL, 5, 0, 0);
K_THREAD_DEFINE(work_tid, 2048, work_thread, NULL, NULL, NULL, 5, 0, 0);
K_THREAD_DEFINE(rpc_tid, 2048, rpc_thread, NULL, NULL, NULL, 5, 0, 0);

int main(void) {
	IRQ_CONNECT(RPC_IRQ, 1, ingress_isr, NULL, 0);
	irq_enable(RPC_IRQ);
	return 0;
}
