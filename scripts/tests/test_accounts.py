import json
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")
sys.path.insert(0, str(ROOT / "scripts"))
import stage_pages  # noqa: E402

ACCOUNT_PAGES = ("account/index.html", "admin/index.html", "privacy/index.html", "terms/index.html")
ACCOUNT_ASSETS = ("assets/js/supabase-config.js", "assets/js/account-core.js", "assets/js/site-header.js", "account/account.js", "admin/admin.js")
SUPABASE_JS = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.0/dist/umd/supabase.js"


def node(script):
    result = subprocess.run([NODE, "-e", script], cwd=ROOT, capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


@unittest.skipUnless(NODE, "Node.js is required to test the account helpers.")
class AccountHelperTests(unittest.TestCase):
    def run_core(self, expression):
        return node(f'const A=require("./assets/js/account-core.js");console.log(JSON.stringify({expression}));')

    def test_every_profile_field_is_optional(self):
        result = self.run_core('A.validateProfile({})')
        self.assertTrue(result["ok"])
        self.assertEqual(result["row"], {"display_name": None, "bio": None, "in_game_name": None, "ally_code": None, "swgoh_gg_url": None})
        blank = self.run_core('A.validateProfile({displayName:"   ",bio:"\\n",allyCode:" ",swgohGgUrl:""})')
        self.assertTrue(blank["ok"])
        self.assertEqual(set(blank["row"].values()), {None})

    def test_profile_validation_matches_the_database_rules(self):
        good = self.run_core('A.validateProfile({displayName:" Holo ",allyCode:"123-456-789",swgohGgUrl:"https://swgoh.gg/p/123456789/"})')
        self.assertTrue(good["ok"])
        self.assertEqual(good["row"]["display_name"], "Holo")
        self.assertEqual(good["row"]["ally_code"], "123456789")
        bad = self.run_core('A.validateProfile({displayName:"x".repeat(41),bio:"y".repeat(501),allyCode:"12345",swgohGgUrl:"https://evil.example/p/123456789/"})')
        self.assertFalse(bad["ok"])
        self.assertEqual(set(bad["errors"]), {"displayName", "bio", "allyCode", "swgohGgUrl"})

    def test_empty_profiles_never_break_display(self):
        self.assertEqual(self.run_core('[A.displayName(null),A.displayName({}),A.displayName({display_name:"  "}),A.displayName({display_name:"Ann"})]'),
                         ["Listener", "Listener", "Listener", "Ann"])
        self.assertEqual(self.run_core('[A.formatAllyCode("123456789"),A.formatAllyCode(""),A.formatAllyCode(null)]'),
                         ["123-456-789", "", ""])

    def test_only_discord_and_google_are_offered(self):
        self.assertEqual(self.run_core('Object.keys(A.PROVIDERS)'), ["discord", "google"])
        self.assertEqual(self.run_core('A.missingProviders([{provider:"google"}])'), ["discord"])
        self.assertEqual(self.run_core('A.missingProviders([{provider:"google"},{provider:"discord"}])'), [])

    def test_accounts_stay_off_until_configured(self):
        self.assertEqual(self.run_core('[A.isConfigured(undefined),A.isConfigured({url:"",publishableKey:""}),'
                                       'A.isConfigured({url:"https://evil.example",publishableKey:"sb_publishable_xxxxxxxxxxxxxxxxxxxx"}),'
                                       'A.isConfigured({url:"https://abcdefgh.supabase.co",publishableKey:"sb_publishable_xxxxxxxxxxxxxxxxxxxx"})]'),
                         [False, False, False, True])
        self.assertIsNone(self.run_core('(globalThis.HC_SUPABASE_CONFIG={url:"",publishableKey:""}, A.createClient())'))

    def test_avatars_are_safe_and_deterministic(self):
        self.assertEqual(self.run_core('[A.initials("Holo Tester"),A.initials(""),A.initials(null),A.initials("darth")]'), ["HT", "L", "L", "DA"])
        self.assertTrue(self.run_core('A.avatarColour("abc")===A.avatarColour("abc")'))
        self.assertEqual(self.run_core('[A.safeAvatarUrl("https://cdn.discordapp.com/avatars/1/a.png"),A.safeAvatarUrl("https://lh3.googleusercontent.com/a/x=s96-c"),'
                                       'A.safeAvatarUrl("https://evil.example/a.png"),A.safeAvatarUrl("https://cdn.discordapp.com.evil.example/avatars/1/a.png"),A.safeAvatarUrl("javascript:alert(1)")]'),
                         ["https://cdn.discordapp.com/avatars/1/a.png", "https://lh3.googleusercontent.com/a/x=s96-c", None, None, None])
        ids = '[{provider:"google",identity_data:{avatar_url:"https://lh3.googleusercontent.com/a/g"}},{provider:"discord",identity_data:{avatar_url:"https://cdn.discordapp.com/avatars/1/d.png"}}]'
        self.assertEqual(self.run_core(f'[A.resolveAvatar({ids},null),A.resolveAvatar({ids},"google"),A.resolveAvatar({ids},"initials"),A.resolveAvatar([],"discord")]'),
                         ["https://cdn.discordapp.com/avatars/1/d.png", "https://lh3.googleusercontent.com/a/g", None, None])

    def test_header_card_comes_only_from_a_stored_session(self):
        script = (
            'const store={};globalThis.localStorage={getItem:k=>k in store?store[k]:null,setItem:(k,v)=>{store[k]=String(v)},removeItem:k=>{delete store[k]}};'
            'const A=require("./assets/js/account-core.js");const cfg={url:"https://abcdefgh.supabase.co",publishableKey:"sb_publishable_xxxxxxxxxxxxxxxxxxxx"};'
            'const out=[A.headerCard(cfg)];'
            'store["sb-abcdefgh-auth-token"]=JSON.stringify({user:{id:"u1",user_metadata:{full_name:"Gee",custom_claims:{global_name:"Dee"}},identities:[]}});'
            'out.push(A.headerCard(cfg));A.saveSummary({id:"u1",name:"Saved Name",avatar_url:"https://evil.example/x",role:"admin"});out.push(A.headerCard(cfg));'
            'A.saveSummary({id:"someone-else",name:"Other"});out.push(A.headerCard(cfg).name);'
            'store["sb-abcdefgh-auth-token"]="not json";out.push(A.headerCard(cfg));A.clearSummary();console.log(JSON.stringify(out));'
        )
        none, from_session, cached, other, broken = node(script)
        self.assertIsNone(none, "signed-out visitors get no card, so no avatar is ever loaded")
        self.assertEqual(from_session["name"], "Dee")
        self.assertEqual(cached["name"], "Saved Name")
        self.assertIsNone(cached["avatar_url"], "unsafe cached avatar URLs are dropped")
        self.assertEqual(other, "Dee", "a cached summary for another account is ignored")
        self.assertIsNone(broken)

    def test_errors_are_explained_in_plain_words(self):
        self.assertIn("wait", self.run_core('A.friendlyError({message:"Too many changes in a short time"})'))
        self.assertIn("permission", self.run_core('A.friendlyError({message:"new row violates row-level security policy"})'))
        self.assertIn("Something went wrong", self.run_core('A.friendlyError(null)'))


class AccountPageTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_new_pages_and_scripts_are_published(self):
        for path in ACCOUNT_PAGES:
            self.assertIn(path, stage_pages.PAGES)
        for path in ACCOUNT_ASSETS:
            self.assertIn(path, stage_pages.ASSETS)

    def test_committed_config_holds_no_secret(self):
        config = self.read("assets/js/supabase-config.js")
        self.assertNotRegex(config, r"sb_secret_|service_role|eyJ[A-Za-z0-9_-]{20,}")
        for path in (ROOT / "supabase").rglob("*"):
            if path.is_file() and ".temp" not in path.parts:
                text = path.read_text(encoding="utf-8", errors="ignore")
                self.assertNotRegex(text, r"sb_secret_[A-Za-z0-9]", path)
                # Only fictional addresses may appear: no real account or seed data is committed.
                for address in re.findall(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", text):
                    self.assertRegex(address.lower(), r"@(?:example\.(?:test|com)|email\.com)$", f"{path}: {address}")

    def test_supabase_library_is_pinned_with_integrity(self):
        for path in ("account/index.html", "admin/index.html"):
            page = self.read(path)
            tag = re.search(r'<script src="https://cdn\.jsdelivr\.net[^>]*>', page).group(0)
            self.assertIn(SUPABASE_JS, tag)
            self.assertRegex(tag, r'integrity="sha384-[A-Za-z0-9+/=]{64}"')
            self.assertIn('crossorigin="anonymous"', tag)

    def test_sign_in_offers_discord_and_google_only(self):
        page = self.read("account/index.html")
        self.assertEqual(re.findall(r'data-sign-in="(\w+)"', page), ["discord", "google"])
        self.assertNotRegex(page, r'type="password"|magic link|signInWithOtp')
        self.assertIn("13 or older", page)
        self.assertIn("local storage", page)

    def test_account_page_works_without_javascript(self):
        page = self.read("account/index.html")
        unavailable = re.search(r'<article[^>]*id="account-unavailable"[^>]*>', page).group(0)
        self.assertNotIn("hidden", unavailable)
        for view in ("account-signed-out", "account-signed-in"):
            self.assertRegex(page, rf'id="{view}"[^>]*hidden')

    def test_admin_page_is_not_indexed(self):
        self.assertIn('name="robots" content="noindex, nofollow"', self.read("admin/index.html"))

    def test_every_page_has_the_header_account_control_and_footer_links(self):
        pages = [p for p in stage_pages.PAGES if not p.startswith("podcast/episodes/")]
        pages += [p.relative_to(ROOT).as_posix() for p in (ROOT / "podcast" / "episodes").glob("episode-*.html")]
        for path in pages:
            page = self.read(path)
            with self.subTest(page=path):
                header = re.search(r'<header class="site-header">(.*?)</header>', page, re.S).group(1)
                # Without JavaScript the header shows a plain "Sign in" link to the account page.
                self.assertRegex(header, r'<div class="account-slot" data-admin-href="[./]*admin/index\.html"><a class="account-link" href="(?:[./]*account/)?index\.html"[^>]*>Sign in</a></div>')
                self.assertNotIn(">Account</a>", header)
                self.assertEqual(page.count('assets/js/site-header.js"'), 1)
                self.assertNotRegex(page, r'<img[^>]+(?:discordapp|googleusercontent)')  # no avatar in static HTML
                footer = re.search(r"<footer>(.*?)</footer>", page, re.S).group(1)
                self.assertRegex(footer, r'href="[./]*privacy/index\.html"')
                self.assertRegex(footer, r'href="[./]*terms/index\.html"')

    def test_generators_produce_the_same_header(self):
        for script in ("scripts/build_qotw.py", "scripts/sync_buzzsprout.py"):
            source = self.read(script)
            self.assertIn('class="account-slot"', source)
            self.assertIn("assets/js/site-header.js", source)
            self.assertNotIn(">Account</a>", source)

    def test_privacy_notice_covers_the_design(self):
        page = self.read("privacy/index.html")
        for phrase in ("13 or older", "Discord", "Google", "Supabase", "6 months", "local storage", "Download",
                       "Discord's or Google's servers", "Initials"):
            self.assertIn(phrase, page)
        self.assertNotRegex(page.lower(), r"we (?:will )?send you (?:an )?email")

    def test_scripts_never_write_untrusted_text_as_html(self):
        for path in ("assets/js/account-core.js", "assets/js/site-header.js", "account/account.js", "admin/admin.js"):
            self.assertNotRegex(self.read(path), r"innerHTML|outerHTML|insertAdjacentHTML|document\.write", path)


if __name__ == "__main__":
    unittest.main()
