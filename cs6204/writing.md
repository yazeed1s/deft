You are helping me write **Project Part Two report** for CS6204.
This is not a tutorial. This is a technical experience report from a systems grad student.

## Metadata (MANDATORY, exact values)

Use these exact values in the LaTeX title block:

- Course: `CS6204 Advanced Topics In Systems: Disaggregated Memory`
- Instructor: `Sam H. Noh`
- Student/Author: `Yazeed Alharhi`

Do not rename, abbreviate, or replace these fields.

## WRITING STYLE CONTRACT (MANDATORY)

Use exactly this writing style:

- personal technical blog style, not polished corporate writing
- systems person voice, thinking while writing
- simple words, dense technical sentences
- minor non-native English texture is fine
- no fake friendly tone, no marketing words
- no “in this post”, no “let’s dive in”, no “we will explore”
- no horizontal rules
- body should be mostly flowing paragraphs, not bullet spam
- short sentences only for emphasis
- say uncertainty when needed

## Inputs you must read first

Read these files and use them as ground truth:

1. `cs6204/deft_report_1.tex`
2. `cs6204/report1_feedback.md`
3. `docs/cxl_architecture.md`
4. `docs/cxl_porting_walkthrough.md`
5. `docs/benchmark_plan.md`
6. `docs/breakage_test_matrix.md`
7. `docs/cloudlab_hardware_snapshot_2026-05-03.md`
8. `docs/rdma_troubleshooting_2026-05-02.md`
9. `script/run_breakage_plan.sh`
10. `script/run_comparison.sh`
11. `script/run_campaign.py`
12. `script/run_bench.py`

Also use available result folders (`deft-resultsv3`, `deft-resultsv4`, `deft-resultsv6`) for concrete numbers.

## Git-history mining (MANDATORY)

Before writing, inspect git history from the first commit in this repository up to current HEAD, then identify files added by me and infer their purpose from file contents.

Required process:

1. Find root commit and scan added files timeline:
   - `git rev-list --max-parents=0 HEAD`
   - `git log --name-status --diff-filter=A --reverse`
2. Build a focused list of files I added that matter for Part 2:
   - include `script/*.sh`, `script/*.py`, `docs/*.md`, `src/cxl/*`, `include/CxlTransport.h`, config/build changes
   - exclude generated artifacts (`build*`, `.aux`, `.log`, binaries, temporary outputs)
3. Read those files and infer practical usage (what each script/tool does in my workflow, not just filename guesses).
4. Use that evidence in the report text.

You must include one dedicated subsection in the final report:

- `\subsection{Repository Additions and Their Role}`

This subsection must:
- summarize major added files/groups
- explain why they were needed (setup, debugging, automation, benchmarking, plotting, CXL porting)
- connect them to reproducibility and to Part 2 outcomes
- mention approximate scale of changes (files touched / insertions-deletions) if available from git

## What this report is about

Part 2 is about porting DEFT from RDMA transport to simulated CXL transport, validating correctness, benchmarking RDMA vs CXL, and stress-testing/breakage behavior.

You must keep continuity with Report 1, but avoid repeating old details unless needed for context.

## Required report structure

Write a full report draft with these section ideas (convert them into LaTeX `\section{}` and `\subsection{}`):

1. Context and Goal
2. What Changed Since Part 1
3. Porting Design: RDMA to CXL
4. Implementation Details (File-Level)
   - include `Repository Additions and Their Role` subsection
5. Experimental Setup: Paper vs My Setup
6. Methodology
7. Reproduction Results
8. Stress/Breakage Results
9. Debugging Journey and Failures
10. Threats to Validity and Fairness
11. Lessons Learned
12. Conclusion
13. Notes (can be short bullets only here)

## Non-negotiable content requirements

- Clearly separate:
    - reproduction attempts
    - breakage/stress attempts
- Explicitly compare:
    - original paper setup vs my actual setup
    - how setup differences may affect results
- Include concrete mechanisms from code:
    - compile-time backend switch (`USE_RDMA` / `USE_CXL`)
    - CXL shared-memory regions
    - RPC queue replacement
    - preserved B+tree logic path
- Include benchmark matrix details:
    - phases A/B/C/D/E
    - what each phase varies/fixes
    - total test counts for each relevant run
- Include resource metrics:
    - throughput, latency, CPU, RSS
    - efficiency commentary (`TP/CPU`, `TP/RSS`)
- Include at least one subsection discussing fairness caveats:
    - RDMA multi-node vs CXL localhost effects
    - what is comparable and what is not
- Include concrete numbers from CSV/summary artifacts wherever possible
- If a number is missing, say it is missing and do not invent

## Output format (MANDATORY)

Do **not** return Markdown prose blocks.
Do **not** return a LaTeX skeleton only.

You must output a **complete LaTeX file** intended to be saved as:

- `cs6204/deft_report_2.tex`

Use a **two-column research-paper format**:

- `\documentclass[10pt,twocolumn]{article}`
- Include needed packages (`geometry`, `graphicx`, `booktabs`, `hyperref`, `listings`, `xcolor`, etc.)
- Use compact margins suitable for class reports
- Add title/author/date
- Include course and instructor metadata near title/author (subtitle line or small block under title)
- Use proper `\section{}` / `\subsection{}`
- Include at least 2 result tables and figure placeholders
- Add bibliography placeholder (`thebibliography`) with at least the DEFT paper and your repo/docs references

The output must compile as a standalone `.tex` document.

## Writing constraints inside LaTeX

- Keep the same voice contract above (systems, dense, slightly non-native texture)
- Do not sound like polished corporate or textbook writing
- Prefer concrete details from the listed files over generic claims
- Use real numbers from CSV/results where available; if missing, explicitly say missing

Do not write generic textbook explanations. Keep it technical, direct, and grounded in the files.
