# Connect Dropbox

Choose **None**, **Read** or **Write** for **Files**, **Sharing** and **File
requests**, then authorize your Dropbox account. No app setup is needed for the
standard sign-in.

## Advanced

### Folder permissions

**Limit to folders** applies to existing folders, with **Read** or **Write**
for **Files**. Give each folder `read-only` or `read-write`; `read-write`
folders also need **Write** for **Files**. Unlisted folders are denied, and the
most specific rule wins. Houston enforces these limits; Dropbox itself grants
broader app permissions. Sharing, file requests and batch operations are
unavailable in this mode. Restart any ongoing file listing after changing
permissions.

### Limits and reconnecting

Uploads support files up to 150 MiB. Full team-space traversal is not supported.
Raising an access level requires signing in again. Remove access anytime in
[Dropbox connected apps](https://www.dropbox.com/account/connected_apps).
