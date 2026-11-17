# Connect Fastmail

1. In Fastmail, open **Settings → Privacy & Security → Manage API tokens**.
2. Create an API token using the **JMAP** protocol. MCP and Dynamic DNS tokens
   are not supported.
3. Enable **Email**. Also enable **Email submission** if you want agents to send
   or reply, and **Masked Email** if you want to list masked addresses.
4. In Houston, choose **Access**:
   - **Read** for browsing, searching, and downloading attachments.
   - **Draft** to also create, update, and delete drafts that you
     review and send yourself in Fastmail. Houston never sends with this level.
   - **Write** to also mark mail read/unread, send drafts, send, reply,
     create folders, move, archive, or delete mail.

   Drafts and other changes need a writable **Email** token; **Email submission**
   is only needed for sending. Leave it off so that even **Write** can
   prepare drafts but never send them.
5. Paste the token into **JMAP API token** and select **Add connection**.

API tokens require a Fastmail plan above Basic.

> Write access permits both moving mail to Trash and permanent deletion. Draft
> access can permanently delete drafts only.
