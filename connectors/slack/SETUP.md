# Connect Slack

1. In Houston, choose the access for each row: **Read** or **None** for
   **Public channels**, **Private channels**, **Search** and **Users**; **Read**,
   **Write** or **None** for **Direct messages** and **Files**; and **Write** or
   **None** for **Reactions** and **Messages**.
2. Select **Add to Slack**, sign in and check the workspace shown.
3. Select **Allow**. If approval is required, ask a workspace admin and reconnect
   after approval.

> Agents see what you can see in the rows you allow, including private channels
> and direct messages. With **Messages** or **Files** at **Write**, they post and
> share files under your name. **Direct messages** at **Write** lets them open
> new direct and group conversations.

| Row | Read | Write |
| --- | --- | --- |
| Public channels | `channels:read`, `channels:history` | |
| Private channels | `groups:read`, `groups:history` | |
| Direct messages | `im:read`, `im:history`, `mpim:read`, `mpim:history` | adds `im:write`, `mpim:write` |
| Search | `search:read` | |
| Users | `users:read` | |
| Files | `files:read` | adds `files:write` |
| Reactions | | `reactions:write` |
| Messages | | `chat:write` |

## Advanced

Add one connection per workspace; Enterprise Grid-wide installations are unsupported.
Raising any row asks you to authorize again. Long channel histories may be slow
because of Slack's app limits; search is often faster.

Deleting the Houston connection removes its saved authorization. Also revoke
Houston on Slack's [app management](https://slack.com/apps/manage) page to end
provider access.
