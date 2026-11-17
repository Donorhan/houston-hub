# Connect GitHub

1. Choose a level for each access row and select **Continue with GitHub**.
2. Authorize **OK Houston**, then [install or configure the app](https://github.com/apps/ok-houston)
   for the account/organization and repositories to share. An organization owner
   may need to approve it.

With Connect with GitHub, Houston enforces the access rows. GitHub's screen lists
the app's full permissions, which are the most any connection can reach; the rows
you choose narrow them for this connection.

> Access is also limited by your own GitHub permissions and the app's installations.
> Change shared repositories under [Installed GitHub Apps](https://github.com/settings/installations)
> without reconnecting.

## Advanced

### Personal access token

Choose **Personal access token** in Houston, set the access rows, and follow
**Create a token on GitHub**. The link opens a
[fine-grained token](https://github.com/settings/personal-access-tokens/new) with
the matching permissions filled in, so GitHub enforces them too:

| Houston access | GitHub permission |
| --- | --- |
| Code and releases | **Contents** |
| Issues and pull requests | **Issues**, **Pull requests** |
| Actions, checks and statuses | **Actions**, **Commit statuses** |
| Gists | **Gists**, which GitHub offers only as write: add it yourself for Gists **Write** |
| Stars | **Starring** |
| Organizations and teams | **Members** |
| Email addresses | **Email addresses** |
| Create and fork repositories | **Administration** |

Select the token's owner and repositories before generating it. Metadata is
automatic. A token belongs to one owner: a token you own cannot hold
**Members**, and one an organization owns cannot hold **Gists**, **Starring** or
**Email addresses**, so use one connection per owner. Code write includes workflow files only when you also grant
**Workflows**. Creating repositories also needs GitHub's **Repository creation**
permission. Check runs and suites need Connect with GitHub or a classic token.

A [classic token](https://github.com/settings/tokens/new) instead needs `repo`,
`workflow`, `read:org`, `gist` and `user:email`. It covers all your repositories
and `repo` permits writes; Houston still enforces the access rows.

### Missing repositories or access

Check installation/token repository selection, organization approval and SAML SSO
(**Configure SSO** on the token). Replace expired/revoked tokens or reconnect a
revoked app. Revoke app access in [Authorized GitHub Apps](https://github.com/settings/apps/authorizations).
