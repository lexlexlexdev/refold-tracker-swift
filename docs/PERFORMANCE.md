# Performance

## Measured baseline

On the developer's Apple Silicon Mac, the previously running release build was sampled
while idle for 30 seconds:

| Main process | Measurement |
| --- | --- |
| CPU (`ps`) | 0.0% at both endpoints |
| CPU time | 2.69 s → 2.69 s |
| Resident memory | 84.2 MiB |

This is an idle observation, not a tracking, energy or network benchmark. WebKit runs
additional content, network and GPU processes; the main-process memory is not the total.

A second 30-second observation showed 64–84 MiB main-process RSS. Three WebKit helper
processes launched alongside the app contributed about 18–29 MiB, giving an estimated
82–113 MiB combined RSS. Helper ownership was inferred from launch timing, not verified
with Instruments. All four processes reported 0.0% CPU at both endpoints; cumulative
CPU time changed only by 0.01 s in the networking helper. RSS is not physical footprint
and changes with memory pressure. These observations precede the idle-timer optimization;
they do not establish the updated build's energy usage.

## Design

- Native display updates once per second during tracking, with 200 ms timer tolerance.
- The native timer is suspended while idle.
- SQLite checkpoints every five seconds during tracking; start/stop are durable writes.
- No periodic history polling. Sync runs on launch/navigation, wake, explicit refresh or mutation.
- Build-specific action discovery fetches dashboard scripts once per WebKit page session.
- WebKit retains the Refold page for authentication and requests. Its JavaScript, analytics
  and third-party widgets can consume resources independently of the native tracker.

Full working-set attribution, active tracking, sleep/wake and energy measurements remain
to be performed. A smaller native HTTP adapter could reduce WebKit overhead, but would
require a separately verified authentication and protocol design.
