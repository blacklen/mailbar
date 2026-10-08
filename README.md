# MailBar

A small macOS menu bar app that shows unread mail from your Gmail accounts.

- An envelope icon in the menu bar, with a dot when you have unread mail
- A dropdown with your newest unread emails, grouped by account (collapsible)
- Notifications when new mail arrives
- Mark one email, or a whole account, as read
- Multiple Gmail accounts

MailBar only looks at the **Primary** tab of each inbox. Promotions, Social and Updates are ignored.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- A Gmail account with 2-Step Verification turned on

## Build and run

```sh
git clone https://github.com/blacklen/mailbar.git
cd mailbar
./build.sh
open build/MailBar.app
```

The first time you open it, a settings window asks for your Gmail address and an app password.

### Optional: stop Keychain prompts after rebuilds

By default the app is signed ad hoc, so macOS asks again for Keychain access each time you rebuild. To avoid that, run this once before building:

```sh
./setup-signing.sh
```

It creates a private code-signing certificate called "MailBar Local Signing" in your login Keychain. It never leaves your Mac.

## Getting an app password

MailBar signs in to Gmail over IMAP with an app password, not your normal password.

1. Turn on 2-Step Verification in your [Google Account security settings](https://myaccount.google.com/security).
2. Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords) and create a password. Any name works, for example "MailBar".
3. Paste the 16-character password into MailBar's settings window.

If the app passwords page says *"The setting you are looking for is not available for your account"*, check that:

- 2-Step Verification is on. Wait a few minutes after turning it on.
- It isn't set up with security keys only.
- Advanced Protection isn't on.
- It isn't a work or school account where the admin has turned app passwords off.

Each account needs its own app password.

## Notifications

If no notifications appear, open System Settings → Notifications → MailBar and turn on **Allow notifications**.

MailBar doesn't notify for mail that is already unread when it starts, only for mail that arrives after that.

## Privacy

- App passwords are stored in the macOS Keychain. Account addresses are stored in the app's preferences.
- MailBar connects only to `imap.gmail.com`.
- Checking mail is read-only. The only changes MailBar makes to your mail are the **Mark as read** buttons.

## Known issues

- Now and then one account shows *"Gmail didn't respond in time."* The next check, a minute later, usually succeeds.
- Clicking an email opens it in Gmail using its thread ID. If Gmail can't find it, you land on the inbox.

## License

[MIT](LICENSE)
