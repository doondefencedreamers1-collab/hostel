# admin-users Edge Function: Supabase Dashboard se deploy kaise karein

Yeh function **sirf asli Director** ke liye hai. Isse Director app se **Manager** ka login:
- bana sakta hai,
- badal sakta hai (naam, mobile, Login ID),
- band / chalu kar sakta hai,
- password reset kar sakta hai,
- hata sakta hai.

Database mein Manager ka role `head_manager` hai.

- Warden (database mein role `manager`) ka account is function se **kabhi nahi** badalta.
- Director ka account bhi is function se **kabhi nahi** badalta.
- Manager is function ko chalaye to jawab hamesha **403** aata hai.

**Koi secret paste nahi karna hai.**
- Function ko 3 cheezein chahiye: `SUPABASE_URL`, `SUPABASE_ANON_KEY` aur `SUPABASE_SERVICE_ROLE_KEY`.
- Yeh teeno Supabase har Edge Function ko **khud** deta hai.
- Service role key kahin copy / paste nahi karni: na code mein, na app mein, na kisi chat mein.
- File `admin-users/index.ts` mein koi key ya password nahi hai.

Kitna time lagega: lagbhag 10 minute. Class time ke bahar karein.

---

## Step 0: pehle database (sirf ek baar)

Yeh function `027_roles_permissions.sql` ke bina nahi chalta. Woh file:
- naya role `head_manager` banati hai;
- table `user_admin_log` banati hai, jismein har kaam ka record jaata hai.

1. Supabase ka **backup** lein: Dashboard, phir Database, phir Backups.
2. SQL Editor kholein, **New query** dabayein, poori `027_roles_permissions.sql` paste karein aur **Run** karein.
   - Neeche 2 lines dikhengi:
     - `director | 9 | ...`
     - `head_manager | 6 | ...`
   - (Agar aap `../sql/RUN_ORDER.md` ke steps se 027 pehle hi chala chuke hain to yeh step dobara nahi karna.)
   - Agar `027 RUKA: ...` aaye to **kuch nahi badla**. Message ka screenshot Claude ko bhejein.
3. Ek aur New query kholein, `027_check.sql` paste karein aur Run karein. **Har row mein `ok` = true** hona chahiye.

---

## Step 1: function banana

1. Supabase Dashboard kholein aur apna DDD Hostel project chunein.
2. Baayein menu mein **Edge Functions** par click karein.
3. **Deploy a new function** dabayein, phir **Via Editor** chunein.
4. Function ka naam bilkul yahi likhein: **`admin-users`** (chhote akshar, beech mein dash).
5. Editor mein pehle se jo sample code hai, use **poora select karke hata dein**.
6. Claude ki di hui file `admin-users/index.ts` kholein.
   - **Sab kuch copy** karein (Ctrl+A, phir Ctrl+C).
   - Editor mein **paste** karein (Ctrl+V).
7. **Deploy function** button dabayein. 10 se 30 second mein "Deployed" ya "Successfully deployed" dikhega.

## Step 2: setting check karein (JWT verify ON)

1. Edge Functions list mein **admin-users** par click karein, phir **Details** (ya Settings) tab kholein.
2. **Verify JWT** **ON** rehna chahiye. Kabhi iska naam "Enforce JWT Verification" hota hai.
   - Default ON hi hota hai.
   - Agar OFF hai to ON karke **Save** karein.
3. **Secrets** mein kuch add nahi karna.
   - Edge Functions ke Secrets page par `SUPABASE_URL`, `SUPABASE_ANON_KEY` aur `SUPABASE_SERVICE_ROLE_KEY` "default" ke roop mein pehle se dikhte hain.
   - Unhe na badlein, na copy karein.

## Step 2b: login email ki setting dekh lein (sirf dekhna, 1 minute)

Manager apna naam, mobile ya email app se nahi badal sakta (database rokta hai). Lekin login ka email Supabase Auth mein alag se hota hai.

1. Supabase Dashboard -> **Authentication** -> **Sign In / Providers** (ya **Providers**) -> **Email** kholein.
2. **Secure email change** **ON** hona chahiye (default ON hota hai). OFF ho to ON karke **Save** karein.
3. **Confirm email** wali setting ko **mat chhedein** (wardens ka sign-up isi par chalta hai).
4. Screenshot bhej dein ki "Confirm email" ON hai ya OFF.
   - Agar "Confirm email" **OFF** hai to ek technical Manager app ke bahar se apna login email badal sakta hai. Isse use **koi nayi power nahi milti** (role, hostel, paise sab database se tay hote hain). Director ko Managers screen par Login ID badla hua dikhega; **Edit** se wapas sahi Login ID daal dein, ya **Login band karein**.

## Step 3: 2 minute ka check (app update se pehle)

1. admin-users function page par **Test** (ya "Invoke") button dabayein.
   - Method `POST` rakhein.
   - Body mein yeh likhein:
     ```json
     { "action": "list_managers" }
     ```
   - Test panel Director ke login se nahi bhejta, isliye jawab **401** aana chahiye. Inmein se koi bhi jawab theek hai:
     - `{ "ok": false, "error": "Login zaroori hai. App mein dobara login karein.", ... }`
     - `Missing authorization header`
   - Iska matlab hai ki function chal raha hai aur bina Director ke login ke kuch nahi karne deta.
   - Agar `"code": "config"` aaye to function ko keys nahi mili. Claude ko batayein.
2. **Logs** tab kholein. Koi laal error nahi hona chahiye.

## Step 4: asli check (jab naye app ka "Managers" screen live ho jaaye)

Director ke login se karein, kisi khaali time par:

1. Managers screen par **+ Naya Manager** dabayein aur yeh bharein:
   - naam: "Test Manager"
   - mobile: 10 digit (+91 lagana zaroori nahi)
   - Login ID: `testmgr01`
   - password: kam se kam 8 akshar
   - **Save** dabayein. Neeche list mein naya Manager "Active" ke saath dikhna chahiye.
2. Doosre phone par login karein:
   - Login box mein sirf `testmgr01` likhein. App khud `@ddd-hostel.app` jod deta hai.
   - Phir password daalein.
   - Manager ko Salary aur Activity Log dikhne chahiye.
   - Warden Approvals mein woh warden approve / remove kar sake. Director ko woh kabhi na badal sake.
3. Director se Manager ka mobile ya naam badlein (Manager ke card par **✎ Edit**). Manager khud apna naam / mobile nahi badal sakta, yeh database rokta hai.
4. Director se **Login band karein** dabayein. Test phone par app refresh karein:
   - power turant band ho jaani chahiye;
   - dobara login nahi hona chahiye.
5. **Login chalu karein** dabayein, phir **Password reset**. Naye password se login hona chahiye.
6. **Remove** dabayein. Login band ho jaana chahiye. List mein woh "Removed" dikhega (history ke liye).
7. Warden ke login se Managers screen dikhni hi nahi chahiye.
8. SQL Editor mein yeh chalayein:
   ```sql
   select created_at, actor_name, action, target_name, ok, error from public.user_admin_log order by created_at desc limit 20
   ```
   - Har kaam ki ek line dikhni chahiye.
   - Password kahin nahi dikhega.

**Agar kisi Manager ka password leak ho jaaye**, to yeh order rakhein:
1. Pehle **Login band karein** dabayein. Database us Manager ki power turant band kar deta hai, chahe uska purana login phone par abhi khula ho.
2. Phir **Password reset** karein.
3. Phir **Login chalu karein** dabayein.

## Code baad mein badalna ho

1. Edge Functions mein **admin-users** kholein, phir **Code** tab.
2. Purana code hata kar naya paste karein.
3. **Deploy** dabayein.

Function ko delete karne ki zaroorat nahi hai.

## Kuch gadbad ho to (rollback)

- **Sirf function band karna:**
  - Edge Functions mein admin-users kholein, phir Settings / Details, phir **Delete function**.
  - App ka baaki sab (fees, students, salary) is function par nirbhar nahi hai, sab chalta rahega. Sirf Managers screen kaam nahi karega.
- **Database wala hissa wapas lena:**
  - Pehle app se saare Managers ko **Remove** karein.
  - Phir SQL Editor mein `027_undo.sql` chalayein.
  - Log ki rows `backup_027.user_admin_log` mein bachi rehti hain.
  - Agar 028 se 031 tak koi file chal chuki hai to `027_undo` ruk jaayega aur batayega ki pehle kaunsa undo chalana hai.

## Aam problems

| Kya dikha | Matlab / kya karein |
|---|---|
| Logged-in Director ko bhi `401 Invalid JWT` dikhe (gateway ka English message) | Project naye "JWT signing keys" use kar raha hai. admin-users ke Details mein **Verify JWT OFF** karke Save karein. Function andar se khud login check karta hai, isliye yeh safe hai. Claude ko bhi batayein. |
| `Role 'head_manager' database mein nahi hai. Pehle 027_roles_permissions.sql chalayein.` | Step 0 nahi chala. Woh chalayein. |
| `Database mein kaam nahi hua (read user_admin_log)` | 027 nahi chala, ya abhi abhi chala hai. 1 minute ruk kar dobara try karein. |
| `Yeh Login ID / email Supabase ne nahi maana` | Abhi ke liye Login ID mein poora asli email likhein (jaise naam@gmail.com) aur Claude ko batayein. |
| `Yeh Login ID / email pehle se kisi doosre account par hai` | Woh Login ID pehle se use mein hai, hataye gaye Manager ka bhi ho sakta hai. Doosra Login ID chunein. |
| `Password Supabase ne kamzor bataya (...)` | Lamba password rakhein, akshar aur ank milakar. |
| `Login band ho gaya hai par profile ... update nahi hua. Dobara ... dabayein` | Internet ya DB ki chhoti dikkat thi. Wahi button dobara dabayein, kaam poora ho jaayega. |
| Mobile par `Mobile number 10 ank ka hona chahiye` | 10 digit likhein. +91, 0091 ya shuru ka 0 apne aap hat jaata hai. |

---

## Developer ke liye (app ka Managers screen)

Call (supabase-js v2, Director logged in):

```js
async function adminUsers(body) {
  const { data, error } = await SB.functions.invoke("admin-users", { body });
  if (!error) return data;                       // { ok: true, action, ... }
  try { return await error.context.json(); }     // { ok: false, error: "<Hinglish>", code }
  catch (_) { return { ok: false, error: "Server se jawab nahi aaya. Internet check karke dobara try karein." }; }
}
```

| action | body | success (status) |
|---|---|---|
| `create_manager` | `full_name, mobile, login_id, password` (password 8 se 72 akshar) | 201 `{ manager, message }` |
| `list_managers` | `include_removed?` (default true) | 200 `{ managers[], count, removed_count }` |
| `update_manager` | `user_id` + koi bhi: `full_name, mobile, login_id` | 200 `{ manager, changed[], message }` |
| `set_active` | `user_id, active` (sirf true / false) | 200 `{ manager, message }` |
| `reset_password` | `user_id, new_password` | 200 `{ user_id, message }` |
| `remove_manager` | `user_id` | 200 `{ manager, message }` |

**Login mapping (app ka login box):**
- Input mein `@` nahi hai to: `input.trim().toLowerCase() + "@ddd-hostel.app"`.
- Input mein `@` hai to woh email jaisa hai waisa use hota hai.
- Login ID ka rule: 3 se 30 akshar, sirf `a-z 0-9 . _ -`.

**Mobile:**
- Sirf digits, aakhri 10.
- Usse pehle sirf 0 / 91 / 0091 / 910 ho sakta hai.
- Number 6 se 9 se shuru hona chahiye.
- Yahi rule 031 (Delete Duplicate) ka hai.

**Database (027) jo khud rokta hai, function chahe kuch bhi bheje:**
- sirf `director` role hi Manager / Director / Accountant ke account badal sakta hai;
- Manager / Warden apna naam, mobile ya email nahi badal sakte;
- band (inactive / removed) Manager ki saari power turant band ho jaati hai;
- `user_admin_log` sirf Director padh sakta hai, Activity Log (`audit_logs`) mein bhi.
