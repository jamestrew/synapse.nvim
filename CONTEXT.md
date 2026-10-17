# Code-anchored conversations

The language of human–agent conversations about code inside Neovim.

## Language

**Comment**:
A message written by a human or coding agent about code, either starting a
conversation or replying within one.

**Thread**:
An initial comment and its replies, treated as one conversation.

**Working-file anchor**:
A recorded file-and-line location or line range to which a comment is attached.
It refers to a working file, not a historical revision or the deleted side of a diff.

**Project root**:
The stable directory identifying the project a conversation concerns. It does
not change when the editor's current working directory changes.

**Session**:
An independent set of code-anchored conversations for one project. Two Neovim
instances in the same project have separate sessions.

**Saved session**:
A session retained for later resumption after its editor instance closes.
