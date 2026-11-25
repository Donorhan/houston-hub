# Connect your Microsoft account

You need a work or school Microsoft account with SharePoint. Personal accounts
such as Outlook.com have no SharePoint and cannot connect.

1. Choose the level for **Access**:
   - **Read** to let agents find and read files, lists and pages without
     changing anything.
   - **Write** to also let agents upload, change, move, copy and delete files
     and folders, and add, change and delete list items.
2. Select **Continue with Microsoft**, sign in with your work or school
   account, and select **Accept** on the permissions Microsoft lists.

Microsoft's permission covers every site you can open: **Read** reads them all,
and **Write** can change anything you can edit, OneDrive files shared with you
included. Houston keeps your authorization on its server, and agent scripts
never see it.

If Microsoft shows **Need admin approval**, your organization requires an
administrator to approve Houston SharePoint. Send them the next section.

## Advanced: approval, changing access and troubleshooting

### For administrators

Microsoft's default settings let only an administrator approve apps that read
all sites. Read and Write are separate permissions: approving Read does not
approve Write, so approve the level your users need.

- **Approve by connecting once.** Add a SharePoint connection in Houston at
  the level your users need, sign in with your administrator account, tick
  **Consent on behalf of your organization**, and select **Accept**. This
  approves only the permissions on that screen, for everyone in your
  organization. You can remove your own connection afterwards.
- **Or approve a request.** If your organization uses admin consent requests,
  approve Houston SharePoint in the
  [Microsoft Entra admin center](https://entra.microsoft.com) under
  **Enterprise applications** > **Admin consent requests**.
- **Limit who can use it.** In **Enterprise applications**, open Houston
  SharePoint, set **Assignment required** to **Yes** under **Properties**, and
  assign users or groups under **Users and groups**. This applies only to
  Houston SharePoint, and assigned users can no longer approve it themselves.
- **Grant admin consent** on the enterprise application's **Permissions** page,
  like an `adminconsent` link without listed permissions, approves both Read
  and Write for everyone. Prefer connecting once at the level you want.

### Changing access and troubleshooting

- To change the access level, edit the connection and connect with Microsoft
  again. Write may need an administrator's approval even when Read did not.
- To revoke every permission you granted Houston SharePoint, remove it from
  [My Apps](https://myapps.microsoft.com). To stop using one connection, remove
  it in Houston.
- If Microsoft says you can't sign in with a personal account, connect with a
  work or school account instead.
- A connection reaches your organization's own SharePoint, not sites in other
  organizations where you are a guest.
- Microsoft's government and China clouds (GCC High, DoD, 21Vianet) are not
  supported.
