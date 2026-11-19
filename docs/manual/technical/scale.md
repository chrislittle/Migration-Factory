# Scale

## One machine

Most of the time of a move is Azure: stopping, moving and starting the machine.

## Workers

Inside the engine, one worker process handles one machine at a time. The wave's **machines at once** setting is the number of workers: 5, 15, 30 or 60, and 15 by default.

The engine container is sized from the number of workers:

| Workers | Container |
|---|---|
| 1 to 3 | 1 CPU, 2 GiB |
| 4 to 7 | 2 CPU, 4 GiB |
| 8 to 15 | 4 CPU, 8 GiB |

## More than one container

Above 15 machines at once, the service starts more than one container for the wave. Each container takes a share of the number, up to four containers and 60 machines at once. The containers share the run store and lease machines from the same plan, so they never touch the same machine. A container that finds nothing to lease waits while the others still hold machines, and leaves when the wave is done. If one container dies, the others finish the wave.

The Container Apps environment must have cores for the containers. The wave editor reads the environment's quota and says whether the wave fits before it is accepted. The service checks again at start.

The service starts the containers one after the other. If Azure refuses the first container, nothing starts, and the page shows the error. If Azure refuses a later container, the wave runs in the containers that started. The service starts no more containers. The page and the activity log say how many containers run, how many machines at once, and what Azure said. The containers that run do all the machines of the wave, with fewer machines at once.

## Long waves

A single run lasts at most 24 hours. A wave with more machines than that allows is resumed by the service's timer from where it stopped. Each machine's state is in the run store, so nothing is repeated.

## Azure's limits

The bottleneck at scale is Azure's control plane, not the engine. The engine sends a throttled call again, and waits longer before each new try.

## Assessments

An assessment reads the whole scope with Azure Resource Graph in a few queries, however many machines there are. It runs scripts inside no machine.

<!-- next:begin -->

---

**Next:** [The install, inside](install-internals.md)

<!-- next:end -->
