// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/main.rs
//
//

//! Entry point: reads the status-line JSON payload and prints the rendered
//! status line.
//!
//! Reads from `--sample <file>` if given, otherwise from stdin. The
//! `--sample` flag exists specifically so this program can be exercised
//! locally without blocking on an un-piped terminal stdin the way the
//! original script's bare `json.load(sys.stdin)` did.

use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;

struct Args {
    sample: Option<PathBuf>,
    no_color: bool,
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Args {
    let mut sample = None;
    let mut no_color = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--sample" => sample = args.next().map(PathBuf::from),
            "--no-color" => no_color = true,
            _ => {}
        }
    }
    Args { sample, no_color }
}

fn main() -> ExitCode {
    let args = parse_args(std::env::args().skip(1));

    let raw = match &args.sample {
        Some(path) => match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(err) => {
                eprintln!(
                    "claude-status-line: couldn't read {}: {err}",
                    path.display()
                );
                return ExitCode::FAILURE;
            }
        },
        None => {
            let mut buf = String::new();
            // A malformed/empty read here still yields a valid (empty)
            // `buf`, which `render` degrades gracefully rather than erroring on.
            let _ = std::io::stdin().read_to_string(&mut buf);
            buf
        }
    };

    print!("{}", claude_status_line::render(&raw, args.no_color));
    ExitCode::SUCCESS
}
