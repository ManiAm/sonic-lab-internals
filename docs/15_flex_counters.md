# Flex Counters

> **Prerequisites**: [SAI and Syncd](13_sai_and_syncd.md) (syncd's processing loop and the vendor SAI) and [The SAI Object Model](14_sai_object_model.md) (stats and the `get_*_stats` calls).

*This document is planned. It will cover the flex counter infrastructure: how `FlexCounterOrch` writes polling configuration to FLEX_COUNTER_DB, how syncd's `FlexCounter` thread reads it, the counter groups (port, queue, buffer, priority group, watermark), and how results are published to COUNTERS_DB for consumption by the CLI, SNMP, and gNMI telemetry.*

---

**Previous**: [← The SAI Object Model](14_sai_object_model.md) · **Next**: [The BGP Container and FRR →](16_bgp_container.md)
