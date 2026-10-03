/* SPDX-License-Identifier: Apache-2.0 */
#include "api.h"
#include <irq_ctrl.h>
#include <nsi_hw_scheduler.h>
#include <nsi_hws_models_if.h>
#include <nsi_main_semipublic.h>
#include <stddef.h>

/* Use the caller's batches directly for the duration of each grant. */
static const struct batch* inbox;
static struct batch*       outbox;
static unsigned            read_index;
static uint64_t            boundary_time = NSI_NEVER;

/* Run equal-time hardware events before returning the grant to the host. */
static void boundary(void) {
	boundary_time = NSI_NEVER;
}

NSI_HW_EVENT(boundary_time, boundary, 999);

int runner_receive(struct message* message) {
	if (read_index == inbox->count) return 0;
	*message = inbox->messages[read_index++];
	return 1;
}

void runner_send(struct message message) {
	outbox->messages[outbox->count++] = message;
}

static void boot(unsigned id) {
	app_configure(id);
	static char* argv[] = {"case-study", "--no-rt", "--rtc-reset", NULL};
	nsi_init(3, argv); /* Returns when the booted CPU idles. */
}

static void advance(uint64_t until) {
	boundary_time = until;
	nsi_hws_find_next_event();
	while (boundary_time != NSI_NEVER) nsi_hws_one_event();
}

static uint64_t run(uint64_t start, uint64_t until, const struct batch* input, struct batch* output) {
	/* Catch up omitted, event-free time before making new input visible. */
	if (nsi_hws_get_time() < start) advance(start);
	inbox      = input;
	outbox     = output;
	read_index = 0;
	if (inbox->count) hw_irq_ctrl_set_irq(RPC_IRQ);
	advance(until);
	/* The grant boundary is disarmed, so this is a real native deadline. */
	return nsi_hws_get_next_event_time();
}

/* The final linker collects these tables in copy order into one host array. */
static const struct instance_api instance_api
	__attribute__((section(INSTANCE_SECTION), aligned(8), used)) = {boot, run, app_state};
