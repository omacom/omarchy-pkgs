/* SPDX-License-Identifier: MIT */
#include <spa/support/plugin.h>
#include <spa/support/log.h>
SPA_LOG_TOPIC_DEFINE(v4l2_log_topic, "spa.v4l2");
extern const struct spa_handle_factory spa_v4l2_udev_factory;
SPA_EXPORT
int spa_handle_factory_enum(const struct spa_handle_factory **factory, uint32_t *index)
{
    if (!factory || !index) return -EINVAL;
    if (*index > 0) return 0;
    *factory = &spa_v4l2_udev_factory;
    ++*index;
    return 1;
}
