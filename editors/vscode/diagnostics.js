// Reads what `hago check` prints when a file does not check: the first error,
//
//   rejected/mismatch.hgo:3:18: in main: type mismatch: expected String, got Int
//     |
//   3 | main = putStrLn (length [1, 2, 3])
//     |                  ^^^^^^
//
// sometimes followed by more lines of explanation. Kept apart from
// extension.js, which needs VS Code, so that it can be tried with plain node.
'use strict';

const path = require('path');

// One problem: the file it is in (absolute, or null when the error names no
// place), the line and column counted from 0, how many columns the marks under
// the source cover, and the message without the quoted source.
function parseCheckOutput(output, cwd) {
  const lines = output.replace(/\r\n/g, '\n').split('\n');
  while (lines.length > 0 && lines[lines.length - 1].trim() === '') lines.pop();
  if (lines.length === 0) return [];
  const first = lines[0];
  const located = /^(.+?):(\d+):(\d+):\s?(.*)$/.exec(first);
  // the quoted source: "  |", "3 | text", "  |   ^^^"
  const quoted = /^\s*\d*\s\|( |$)/;
  let width = 1;
  const rest = [];
  for (const l of lines.slice(1)) {
    if (quoted.test(l)) {
      const marks = /\|\s*(\^+)\s*$/.exec(l);
      if (marks) width = marks[1].length;
    } else {
      rest.push(l);
    }
  }
  if (!located) {
    // no place: "file: message" or just a message
    const named = /^(.+?\.hgo):\s?(.*)$/.exec(first);
    return [{
      file: named ? path.resolve(cwd, named[1]) : null,
      line: 0,
      column: 0,
      width: 0,
      message: [named ? named[2] : first].concat(rest).join('\n').trim(),
    }];
  }
  return [{
    file: path.resolve(cwd, located[1]),
    line: Math.max(0, parseInt(located[2], 10) - 1),
    column: Math.max(0, parseInt(located[3], 10) - 1),
    width,
    message: [located[4]].concat(rest).join('\n').trim(),
  }];
}

module.exports = { parseCheckOutput };
