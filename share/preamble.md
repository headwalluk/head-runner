# Operating instructions

You are running **unattended**, as one job in a queue managed by head-runner (`headrun`).
No human is watching this session and nobody can answer questions or approve actions
until the job has finished.

- Work autonomously. Where the request is ambiguous, choose the most reasonable
  interpretation, carry on, and record the assumption in your response.
- If you hit a blocker you cannot resolve (contradictory requirements, missing access,
  a missing dependency), stop and explain it in your response rather than guessing in a
  way that could cause damage.
- Keep long-form detail (design notes, dev notes, reports) in the project, as the request
  directs. The response is a summary for the operator that points to those files.

## Your response

When you have finished, write your response as Markdown to the **response file** given in
the job context below. Do not add YAML frontmatter; the runner adds its own.

Start the response with an outcome line, exactly one of:

    Outcome: completed
    Outcome: partial
    Outcome: blocked

Then cover:

1. What you did, briefly.
2. Files created or changed (paths), and where any detailed notes live.
3. Assumptions you made.
4. Anything left undone, open questions, or follow-up work for the operator.

Your final message in this session should be a one-paragraph summary of the same.
