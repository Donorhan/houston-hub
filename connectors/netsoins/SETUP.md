# Connect NETSoins

> NETSoins API keys are issued by Orisha (formerly Teranga Software). Ask your
> Orisha contact or support for a webservice API key for each facility you want
> to connect.

1. Ask Orisha for a **webservice API key** for the facility that can only read
   staff accounts (**Personnel**) and job categories
   (**CatégorieProfessionnelle**), and for its **API access type** if it is not
   `isiapp`.
2. In Houston, enter **NETSoins domain**: the address you open NETSoins at,
   without `https://` or a path, such as `monetablissement.netsoins.org`.
3. Paste **API key**, keep **API access type** at `isiapp` unless Orisha gave
   another one, and save.

## Advanced

### Connection problems

Houston calls `https://<NETSoins domain>/webservice.php/teranga/` and adds the
key and access type to each request.

- If NETSoins answers that the key or access type is invalid, check both with
  Orisha.
- If a firewall in front of NETSoins refuses the request, ask Orisha whether it
  blocks API clients such as Houston, which identifies itself as
  `Houston (+https://ok-houston.com)`.
- If the secure connection fails, the facility's server may only offer old TLS
  settings. Houston requires TLS 1.2 or later with current ciphers, so ask
  Orisha to update the server.

### Several facilities

Every facility has its own NETSoins domain and API key. Add one connection per
facility and name each one after it.
