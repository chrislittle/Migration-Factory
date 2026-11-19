# The Migrations page

The Migrations page holds every migration you have. You pick one at the top of the page, and the rest of the page is that migration. See [Watch a migration](watch.md).

The page reads the migration again at a fixed interval. While you move the pointer on a button, a link or a field in it, or type in a field, it waits. It draws the migration when you move the pointer away, go out of the field, or stop for 10 seconds. **Updated** at the top says when the page last drew it.

## Pick a migration

The button at the top left names the migration you are looking at. Select it to open the list.

Each row in the list is one migration. The row shows the migration's name, a tag for its state, and when it last changed. The project is shown under the name only when the list holds migrations from more than one project. When they all come from the same project, the page header already names it.

The list is grouped by state, in this order.

| Group | Meaning |
|---|---|
| Still being prepared | The wizard was started and never finished. The row offers **Continue setup**, which reopens the wizard where you left it. |
| Waiting for approval | The next wave cannot start until a person acts. The tag says what to do: **accept**, **approve** or **start**. |
| Planned | A wave is ready to start, and nothing waits for a person. |
| In progress | A wave is moving machines now. |
| Needs attention | A machine stopped and waits for a person. A machine that you restored after its stop does not wait. A machine that a restore left stopped waits until somebody uses **Finish the restore**. |
| Completed | Every wave ran, and every machine finished. |
| Other | Anything else, such as a migration that was stopped or paused. |

The **accept** tag means that a person must accept the note about machines defined in code, or the settings of the next wave. The **approve** tag means that a person must approve the next wave. A sign-off of the plan gives each wave its own approval. A change to a wave after this removes the approval of that wave. The **start** tag means that the next wave changed after the sign-off, so the plan does not start it. Select **Start this wave** on that wave, or sign off the plan again. See [Start a migration](start.md).

The list does not show a migration as Completed while a wave is still to run.

## Older migrations

The list shows the migrations of the last 14 days. Below them, **Show N older runs** adds the rest.

Age never hides a migration that is in progress, needs attention, or waits for approval. Those stay in the list however old they are.

## While the page reads

Until the page has read the store, each part of the page says what it is reading. A card says it is reading rather than showing nothing.

The parts are your migrations, the machines in this migration, the quota and the on-demand capacity reservations, the safety copies, and the activity.

The page says **no migrations** only after it read the store. Before that it says it is still reading.

<!-- next:begin -->

---

**Next:** [Watch a migration](watch.md)

<!-- next:end -->
