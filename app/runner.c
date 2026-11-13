/* SPDX-License-Identifier: Apache-2.0 */
/* Runner-side adapter: built into each instance's private native simulator runner. */
#include "api.h"
#include <irq_ctrl.h>
#include <nsi_hw_scheduler.h>
#include <nsi_hws_models_if.h>
#include <nsi_main_semipublic.h>
#include <stddef.h>

/* The host's batches, used directly while the device runs. */
static const struct batch* inbox;
static struct batch*       outbox;
static unsigned            read_index;
static uint64_t            boundary_time = NSI_NEVER;

/* Lowest priority: equal-time hardware events run before advance() returns. */
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

static uint64_t advance(uint64_t until) {
	boundary_time = until;
	nsi_hws_find_next_event();
	while (boundary_time != NSI_NEVER) nsi_hws_one_event();
	/* The boundary is disarmed again, so this is a real deadline of the device. */
	return nsi_hws_get_next_event_time();
}

static void attach(const struct batch* input, struct batch* output) {
	inbox      = input;
	outbox     = output;
	read_index = 0;
}

static void interrupt(unsigned irq) {
	hw_irq_ctrl_set_irq(irq);
}

static const struct instance_api instance_api __attribute__((section(INSTANCE_SECTION), aligned(8), used)) = {
	boot, nsi_hws_get_time, advance, attach, interrupt, app_state,
};
