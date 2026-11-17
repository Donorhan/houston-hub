# Connect HubSpot

1. Choose **None**, **Read** or **Write** for **Contacts**, **Companies**, **Deals**,
   **Tickets** and **Activities**, and select **Authorize connection**.
2. In HubSpot, choose the account to connect, review the permissions Houston asks for
   and select **Connect app**.

> Connecting installs Houston's app in the HubSpot account, which needs a Super Admin
> or a user with the **HubSpot Marketplace access** permission. Raising a level asks
> HubSpot for the extra permissions again.

HubSpot has no separate permissions for activities (notes, tasks, calls, meetings and
logged emails), so Houston enforces the **Activities** level.

## Advanced

### Service key

Choose **Service key or private app access token** in Houston. A Super Admin or a user
with the **Developer tools access** permission can create a
[service key](https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/account-service-keys)
in HubSpot:

1. Go to **Development**, then **Keys** > **Service keys**, and select **Create service key**.
2. Enter a name, select **Add new scope**, tick the scopes below and select **Update**.
3. Select **Create** and confirm.
4. Open the key, select **Show**, then **Copy**, and paste it in Houston as **Access token**.

Scopes to tick:

| Access | Read | Write |
| --- | --- | --- |
| Always | `crm.objects.owners.read`, `sales-email-read` | |
| Contacts | `crm.objects.contacts.read`, `crm.schemas.contacts.read` | also `crm.objects.contacts.write` |
| Companies | `crm.objects.companies.read`, `crm.schemas.companies.read` | also `crm.objects.companies.write` |
| Deals | `crm.objects.deals.read`, `crm.schemas.deals.read` | also `crm.objects.deals.write` |
| Tickets | `crm.objects.tickets.read`, `crm.schemas.tickets.read` | also `crm.objects.tickets.write` |

Houston still enforces each level you choose when the key allows more.

### Existing private app

HubSpot stopped creating legacy private apps on October 26, 2026, but existing ones
keep working. In HubSpot, go to **Development** > **Legacy apps**, open the app, then on
the **Auth** tab select **Show token** and **Copy**. Paste it in Houston as **Access
token**. An older app may hold the `tickets` scope instead of the `crm.objects.tickets`
scopes; it covers tickets too.

### Missing data or permission errors

- If agents report a missing scope, add it to the service key or private app (select
  **Edit** on the key), or connect again with HubSpot.
- A rotated, expired or deleted key stops working: paste the new key in the connection.
- To revoke Houston's access, uninstall Houston from the account's **Connected Apps**
  in HubSpot, or delete the key, then remove the connection in Houston.
- HubSpot limits how many requests an app or key may make every 10 seconds, and service
  keys and private apps also share a daily quota for the account; busy accounts can
  briefly reach these limits.
