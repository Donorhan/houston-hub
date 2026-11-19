# Connect Gmail

1. Choose a level for each row of **Access**:
   - **Messages**: **Read** lets agents search and read your mail, threads,
     attachments and labels. **Organize** also lets them archive, mark messages
     read or unread, apply labels, and create, rename and delete labels.
   - **Drafts**: **Create** lets agents read your drafts and write new ones.
     You review and send them yourself in Gmail. **Manage** also lets them edit
     and delete drafts.
   - **Sending**: **Send** lets agents send new mail and replies from your
     address.

   Leave a row on **None** to turn it off. Gmail stores drafts as messages, so
   Messages at Read can also show your drafts.
2. Choose an available sign-in option and select **Connect Gmail**.
3. Choose your Google account and approve access. With Connect with Google, if
   Google shows a checkbox per permission, tick them all: Houston refuses a
   partial grant. You will return to Houston.

Houston calls Gmail only when your agent asks it to and never syncs your mailbox
in the background. Connect with Google asks only for the permissions of the
levels you choose, so Google itself refuses anything beyond them, and it does
not grant access to your other Google services. Houston never deletes messages
or moves them to Trash or Spam; deleted drafts are removed for good.

> If you connect with Composio, it requires full Gmail access. Houston limits its use to the access level
> you select.

## Advanced

- To change **Access**, edit the connection and connect the same mailbox again.
  Add a separate connection for a different mailbox.
- Agents send from your account's own address. To reply in a conversation, they
  need Messages at Read or above.
- Removing a connection stops Houston from using it. To revoke access in Google
  too, remove Composio (or Houston for direct sign-in) from
  [your Google Account's connections](https://myaccount.google.com/connections).
  This also affects other connections using that app.
- If your Google Workspace blocks the connection, ask your administrator to
  allow the app shown on Google's consent screen.
