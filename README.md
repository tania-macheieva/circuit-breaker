# Circuit Breaker

A Ruby implementation of the **Circuit Breaker pattern** for protecting applications from repeatedly calling an unstable or unavailable dependency.

The circuit has three states:

* **Closed** — requests are allowed normally. Consecutive failures are counted, and the circuit opens after reaching the configured failure threshold.
* **Open** — requests are blocked immediately. After the configured cooldown period, the circuit moves to `HalfOpen`.
* **HalfOpen** — a limited number of trial requests are allowed to check whether the dependency has recovered. Successful trials close the circuit; a failure or timeout opens it again.

### Features

* Configurable failure threshold
* Configurable number of trial calls in `HalfOpen`
* Configurable `Open` state duration
* Per-call timeout using Ruby's `Timeout`
* Timeouts are treated as failures
* Thread-safe state management using `Monitor`
* Protection against stale results from previous circuit states using an epoch counter
* Injectable clock for deterministic testing

### Tests

The RSpec test suite covers:

* State transitions between `Closed`, `Open`, and `HalfOpen`
* Failure threshold handling
* Failure counter reset after a successful call
* Blocking calls while the circuit is open
* Per-call timeouts
* Recovery after the open-state duration
* Reopening after a failed or timed-out trial call
* Concurrent trial calls and the `HalfOpen` limit

The project is intentionally implemented with a small API and no external runtime dependencies, making the Circuit Breaker behavior easy to study, test, and reuse.
