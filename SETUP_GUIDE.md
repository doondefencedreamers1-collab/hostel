# DDD Hostel — LIVE karne ki guide (10–15 minute)

Aapke paas 4 cheezein hain:
- `supabase/001_schema.sql` — database (saare tables)
- `supabase/002_rls.sql` — login + role security
- `supabase/003_seed.sql` — sample data (optional)
- `index.html` — poori app (ek hi file)

Code 100% taiyaar hai. Sirf neeche ke steps aapko karne hain (kyunki account aur keys aapke hain).

---

## STEP 1 — Supabase project banao (free)
1. https://supabase.com par jao → **Start your project** → GitHub/email se sign up.
2. **New project** dabao. Name: `ddd-hostel`. Ek strong **database password** rakho (likh ke rakho).
3. Region: **Mumbai / Singapore** (India ke liye fast). **Create** dabao. 2 min wait.

## STEP 2 — Database banao
1. Left menu → **SQL Editor** → **New query**.
2. `001_schema.sql` ka poora text copy karke paste karo → **Run** (green button). "Success" aana chahiye.
3. Phir `002_rls.sql` paste karke **Run**.
4. (Optional) Sample data ke liye `003_seed.sql` paste karke **Run**.

## STEP 3 — Login users banao
1. Left menu → **Authentication** → **Users** → **Add user** → **Create new user**.
2. Director ke liye: email `director@ddd.com`, password (jo yaad rahe), aur **Auto Confirm User** ✅ on karo. Create.
3. Aise hi banao: `manager@ddd.com`, `accountant@ddd.com` (jitne chaho).
4. Ab har user ko role do — **SQL Editor** mein yeh chalao (apne emails daal ke):
   ```sql
   update users set role_id=(select id from roles where name='director')   where email='director@ddd.com';
   update users set role_id=(select id from roles where name='manager')    where email='manager@ddd.com';
   update users set role_id=(select id from roles where name='accountant') where email='accountant@ddd.com';
   ```
5. **Manager ko hostel assign karo** (manager sirf apna hostel dekhega). Hostel ki id `select id,name,code from hostels;` se lo:
   ```sql
   insert into user_hostel_assignments(user_id,hostel_id)
   values ((select id from users where email='manager@ddd.com'),
           (select id from hostels where code='DDB1'));
   ```

## STEP 4 — App mein keys daalo
1. Supabase → **Project Settings** (gear icon) → **API**.
2. Do cheezein copy karo: **Project URL** aur **anon public** key.
3. `index.html` file ko Notepad/kisi editor mein kholo. Sabse upar yeh do line dikhengi:
   ```js
   const SUPABASE_URL  = "https://YOUR-PROJECT.supabase.co";
   const SUPABASE_ANON = "YOUR-ANON-PUBLIC-KEY";
   ```
   Inme apni URL aur key paste karke **save** karo.

## STEP 5 — App ko live karo (URL milega)
**Sabse aasan tareeka (no coding):**
1. https://app.netlify.com/drop par jao.
2. `index.html` file ko bas **drag-and-drop** kar do.
3. Bas! Aapko ek live URL mil jayega (jaise `random-name.netlify.app`). Phone par kholo, director email/password se login karo.

*(Ya GitHub par daal ke Vercel/Netlify se connect kar sakte ho — par drag-drop sabse fast hai.)*

---

## Kya-kya kaam karega (live)
- **Login + 4 roles**: Director sab dekhega; Manager sirf apna hostel; Accountant sirf paisa. Yeh database (RLS) se lagega — bilkul secure.
- Dashboard (live KPIs + charts), Hostels, Rooms & Beds (visual grid + allocate), Students (+ Call/WhatsApp), Roster + Print, Fees (auto monthly dues + receive), Expenses (+ approve/reject), Staff (+ attendance), Complaints, Inventory, Audit Log.
- Saara data **cloud par** — sab warden apne phone se ek hi data dekhenge. Audit log mein kisne kya badla sab record hoga.

## Abhi baaki (agle phase mein add karenge)
- Photo / ID / bill **image upload** (Supabase Storage bucket — 2 min setup, main code de dunga)
- **PDF/Excel export** + detailed reports with filters
- **AI features** (monthly summary, expense anomaly, fee-risk) — ek chhota server function, main bana dunga
- **WhatsApp/SMS auto-alerts**

## Dikkat aaye to
- Login ke baad khaali dikhe → STEP 3 ka role waala SQL chalaya? Bina role ke user ko kuch nahi dikhta.
- "permission denied" → `002_rls.sql` chala tha kya? Wahi security lagata hai.
- Manager ko kuch nahi dikhta → STEP 3.5 (hostel assign) zaroori hai.
- Koi bhi error aaye to mujhe screenshot/text bhej do, main theek kara dunga.
