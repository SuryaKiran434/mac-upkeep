#!/usr/bin/env python3
"""Send email notifications for mac-upkeep (success or error)."""

import os
import sys
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from pathlib import Path


def load_env(path: Path) -> None:
    """Load key=value pairs from a .env file into os.environ."""
    if not path.exists():
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def send(subject: str, body: str, html_body: str = "",
         sender: str = "", password: str = "", to: str = "") -> int:
    """Send email via Gmail SMTP.

    Returns 0 on success, 1 on credential/config error, 2 on SMTP error.
    """
    base_dir = Path(__file__).parent

    # If credentials not passed as arguments, try .env
    if not sender or not password or not to:
        load_env(base_dir / ".env")
        sender = sender or os.environ.get("SENDER_EMAIL", "")
        password = password or os.environ.get("SENDER_APP_PASSWORD", "")
        to = to or os.environ.get("RECIPIENT_EMAIL", "")

    if not all([sender, password, to]):
        print("[notify] ERROR: Missing credentials (SENDER_EMAIL, SENDER_APP_PASSWORD, RECIPIENT_EMAIL)",
              file=sys.stderr)
        return 1

    # Create message with both plain text and HTML (if provided)
    if html_body:
        msg = MIMEMultipart("alternative")
        msg.attach(MIMEText(body, "plain", "utf-8"))
        msg.attach(MIMEText(html_body, "html", "utf-8"))
    else:
        msg = MIMEText(body, "plain", "utf-8")

    msg["Subject"] = subject
    msg["From"]    = f"Brew Automation <{sender}>"
    msg["To"]      = to

    try:
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as smtp:
            smtp.login(sender, password)
            smtp.sendmail(sender, to, msg.as_string())
        print(f"[notify] Email sent to {to}")
        return 0
    except smtplib.SMTPAuthenticationError:
        print("[notify] ERROR: Gmail authentication failed. Verify SENDER_APP_PASSWORD.",
              file=sys.stderr)
        return 1
    except smtplib.SMTPException as exc:
        print(f"[notify] ERROR: SMTP failed ({type(exc).__name__}). System may retry later.",
              file=sys.stderr)
        return 2
    except OSError:
        print("[notify] ERROR: Network error. Check internet connection.",
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: notify.py <subject> <body> [html_body] [sender] [password] [recipient]",
              file=sys.stderr)
        sys.exit(1)

    subject = sys.argv[1]
    body = sys.argv[2]
    html_body = sys.argv[3] if len(sys.argv) > 3 else ""
    sender = sys.argv[4] if len(sys.argv) > 4 else ""
    password = sys.argv[5] if len(sys.argv) > 5 else ""
    recipient = sys.argv[6] if len(sys.argv) > 6 else ""

    exit_code = send(subject=subject, body=body, html_body=html_body,
                     sender=sender, password=password, to=recipient)
    sys.exit(exit_code)
