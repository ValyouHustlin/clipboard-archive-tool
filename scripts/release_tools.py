#!/usr/bin/env python3
"""Helpers for scripts/release.sh. Standard library only.

  release_tools.py notes CHANGELOG VERSION BUILD --md OUT.md --html OUT.html
      The CHANGELOG entry "## VERSION build BUILD - DATE" as release notes.
  release_tools.py appcast --out FILE [--existing FILE] --version BUILD
      --short VERSION --url URL --length BYTES --ed-signature SIG
      --notes-html FILE [--minimum-system 13.0] [--title NAME]
      Writes an appcast with this item first and any older items after it.
  release_tools.py leak-scan FILE...
      Fails (exit 1) when a file names a home directory, an email address, a
      tailnet host or a private address. Release files go to strangers.
"""
import argparse
import email.utils
import html
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def changelog_section(changelog, version, build):
    heading = re.compile(r"^## " + re.escape(version) + r" build " + re.escape(build) + r" - (.+)$")
    lines = open(changelog, encoding="utf-8").read().splitlines()
    for start, line in enumerate(lines):
        match = heading.match(line)
        if match:
            body = []
            for following in lines[start + 1:]:
                if following.startswith("## "):
                    break
                body.append(following)
            return match.group(1).strip(), "\n".join(body).strip()
    raise SystemExit(f"no CHANGELOG entry '## {version} build {build} - <date>'")


def inline(text):
    escaped = html.escape(text, quote=False)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)


def markdown_to_html(body):
    """Enough Markdown for a CHANGELOG entry: paragraphs and '- ' lists."""
    blocks, items, paragraph = [], [], []

    def flush_paragraph():
        if paragraph:
            blocks.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def flush_items():
        if items:
            blocks.append("<ul>" + "".join("<li>" + inline(" ".join(i)) + "</li>" for i in items) + "</ul>")
            items.clear()

    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_paragraph()
            flush_items()
        elif line.startswith("- "):
            flush_paragraph()
            items.append([line[2:].strip()])
        elif items and raw.startswith("  "):
            items[-1].append(line.strip())
        else:
            flush_items()
            paragraph.append(line.strip())
    flush_paragraph()
    flush_items()
    return "\n".join(blocks)


def command_notes(args):
    date, body = changelog_section(args.changelog, args.version, args.build)
    with open(args.md, "w", encoding="utf-8") as out:
        out.write(f"# Clipboard Archive {args.version} (build {args.build}) - {date}\n\n{body}\n")
    with open(args.html, "w", encoding="utf-8") as out:
        out.write(markdown_to_html(body) + "\n")


def command_appcast(args):
    if args.existing:
        tree = ET.parse(args.existing)
        channel = tree.getroot().find("channel")
        if channel is None:
            raise SystemExit("existing appcast has no channel")
        old_items = [item for item in channel.findall("item")
                     if item.findtext(f"{{{SPARKLE_NS}}}version") != args.version]
        for item in channel.findall("item"):
            channel.remove(item)
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = args.title
        tree = ET.ElementTree(root)
        old_items = []

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{args.title} {args.short}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.short
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.minimum_system
    ET.SubElement(item, "description").text = open(args.notes_html, encoding="utf-8").read()
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": args.ed_signature,
    })
    for position, entry in enumerate([item] + old_items):
        channel.insert(position + 1, entry)
    ET.indent(tree)
    tree.write(args.out, encoding="utf-8", xml_declaration=True)


LEAKS = [
    ("home directory", re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+")),
    ("email address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("tailnet host", re.compile(r"[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net")),
    ("private address", re.compile(r"\b(?:100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])|10|192\.168)\.\d{1,3}\.\d{1,3}\b")),
]
# Mach-O text from Apple's toolchains carries these; they name no person.
ALLOWED = [
    re.compile(r"^/Users/Shared\b"),
    re.compile(r"^[A-Za-z0-9._%+-]+@[0-9]+(?:\.[0-9]+)+$"),  # symbol@version shapes
]


def readable_text(path):
    data = open(path, "rb").read()
    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
        return subprocess.run(["/usr/bin/strings", "-a", path], capture_output=True, text=True, check=True).stdout
    return data.decode("utf-8", errors="replace")


def command_leak_scan(args):
    findings = []
    for path in args.files:
        text = readable_text(path)
        for label, pattern in LEAKS:
            for match in pattern.finditer(text):
                value = match.group(0)
                if any(allowed.search(value) for allowed in ALLOWED):
                    continue
                findings.append(f"{path}: {label}: {value}")
    if findings:
        print("leak scan failed: release files name things a stranger should not see", file=sys.stderr)
        for finding in sorted(set(findings)):
            print("  " + finding, file=sys.stderr)
        return 1
    print(f"leak scan ok: {len(args.files)} files")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    notes = commands.add_parser("notes")
    notes.add_argument("changelog")
    notes.add_argument("version")
    notes.add_argument("build")
    notes.add_argument("--md", required=True)
    notes.add_argument("--html", required=True)

    appcast = commands.add_parser("appcast")
    appcast.add_argument("--out", required=True)
    appcast.add_argument("--existing")
    appcast.add_argument("--title", default="Clipboard Archive")
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--short", required=True)
    appcast.add_argument("--url", required=True)
    appcast.add_argument("--length", required=True, type=int)
    appcast.add_argument("--ed-signature", required=True)
    appcast.add_argument("--notes-html", required=True)
    appcast.add_argument("--minimum-system", default="13.0")

    scan = commands.add_parser("leak-scan")
    scan.add_argument("files", nargs="+")

    args = parser.parse_args()
    if args.command == "notes":
        command_notes(args)
    elif args.command == "appcast":
        command_appcast(args)
    else:
        sys.exit(command_leak_scan(args))


if __name__ == "__main__":
    main()
