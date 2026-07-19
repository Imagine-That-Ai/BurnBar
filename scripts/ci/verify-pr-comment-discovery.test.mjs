import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const prReview = readFileSync(
  new URL("../../.github/workflows/pr-review.yml", import.meta.url),
  "utf8",
);
const qa = readFileSync(
  new URL("../../.github/workflows/qa.yml", import.meta.url),
  "utf8",
);

// Extract the comment-posting step block from each workflow. These slices
// isolate the actions/github-script step that discovers, updates, or creates
// the bot comment — the exact code path that must stay entirely on GraphQL.
const prReviewCommentStep = prReview.slice(
  prReview.indexOf("Post review comment"),
);
const qaCommentStep = qa.slice(
  qa.indexOf("Post QA report as PR comment"),
);

test("pr-review discovers existing bot comments via paginated GraphQL, not REST listComments", () => {
  // Regression: the REST endpoint GET /issues/{number}/comments returns
  // persistent 503 on large PRs; GraphQL pullRequest.comments(last:N) does not.
  // The discovery call must use github.graphql with a paginated
  // pullRequest.comments query — never github.rest.issues.listComments.
  assert.doesNotMatch(
    prReviewCommentStep,
    /github\.rest\.issues\.listComments/,
    "pr-review must not use REST issues.listComments for comment discovery (503 on large PRs)",
  );
  assert.match(
    prReviewCommentStep,
    /github\.graphql/,
    "pr-review must use github.graphql for comment discovery",
  );
  assert.match(
    prReviewCommentStep,
    /pullRequest\s*\(\s*number\s*:\s*\$\w+\s*\)/,
    "pr-review GraphQL query must select the pullRequest node by number",
  );
  assert.match(
    prReviewCommentStep,
    /comments\s*\(\s*last\s*:\s*\d+\s*,\s*before\s*:\s*\$\w+\s*\)/,
    "pr-review GraphQL query must paginate comments with last:N, before:$cursor",
  );
  // The pagination loop must advance the cursor until the marker comment is
  // found or pages are exhausted.
  assert.match(
    prReviewCommentStep,
    /while\s*\(\s*!.*&&\s*before\s*\)/,
    "pr-review must loop pagination until the bot comment is found or pages exhausted",
  );
  // The pullRequest.id must be captured as subjectId for the addComment
  // mutation fallback.
  assert.match(
    prReviewCommentStep,
    /subjectId\s*=\s*pullRequest\.id/,
    "pr-review must capture pullRequest.id as subjectId for addComment",
  );
});

test("qa discovers existing bot comments via paginated GraphQL, not REST issues comments", () => {
  // Same regression: the REST endpoint GET /issues/{number}/comments returns
  // persistent 503 on large PRs. The discovery call must use github.graphql
  // with a paginated pullRequest.comments query — never gh api or
  // github.rest.issues.listComments.
  assert.doesNotMatch(
    qaCommentStep,
    /github\.rest\.issues\.listComments/,
    "qa must not use REST issues.listComments for comment discovery (503 on large PRs)",
  );
  assert.doesNotMatch(
    qaCommentStep,
    /gh\s+api\s+.*\/issues\/.*\/comments/,
    "qa must not use REST gh api repos/.../issues/{pr}/comments for comment discovery",
  );
  assert.match(
    qaCommentStep,
    /github\.graphql/,
    "qa must use github.graphql for comment discovery",
  );
  assert.match(
    qaCommentStep,
    /pullRequest\s*\(\s*number\s*:\s*\$\w+\s*\)/,
    "qa GraphQL query must select the pullRequest node by number",
  );
  assert.match(
    qaCommentStep,
    /comments\s*\(\s*last\s*:\s*\d+\s*,\s*before\s*:\s*\$\w+\s*\)/,
    "qa GraphQL query must paginate comments with last:N, before:$cursor",
  );
  assert.match(
    qaCommentStep,
    /while\s*\(\s*!.*&&\s*before\s*\)/,
    "qa must loop pagination until the marker comment is found or pages exhausted",
  );
  assert.match(
    qaCommentStep,
    /subjectId\s*=\s*pullRequest\.id/,
    "qa must capture pullRequest.id as subjectId for addComment",
  );
});

test("pr-review updates and creates comments via GraphQL mutations, not REST issues APIs", () => {
  // Even REST PATCH /issues/comments/{id} and POST /issues/{pr}/comments
  // return 503 on large PRs. The update and create must use GraphQL mutations:
  // updateIssueComment for updates, addComment for creates.
  assert.match(
    prReviewCommentStep,
    /mutation\s+Update\w*Comment.*updateIssueComment\s*\(\s*input\s*:\s*\{\s*id\s*:\s*\$id\s*,\s*body\s*:\s*\$body\s*\}\s*\)/s,
    "pr-review must update via GraphQL updateIssueComment mutation",
  );
  assert.match(
    prReviewCommentStep,
    /mutation\s+Create\w*Comment.*addComment\s*\(\s*input\s*:\s*\{\s*subjectId\s*:\s*\$subjectId\s*,\s*body\s*:\s*\$body\s*\}\s*\)/s,
    "pr-review must create via GraphQL addComment mutation",
  );
  // Prohibit all REST issues comment APIs (listComments, updateComment,
  // createComment) — the entire comment lifecycle must be GraphQL.
  assert.doesNotMatch(
    prReviewCommentStep,
    /github\.rest\.issues\.\w+Comment/,
    "pr-review must not use any github.rest.issues comment API (listComments, updateComment, createComment all 503 on large PRs)",
  );
});

test("qa updates and creates comments via GraphQL mutations, not REST issues APIs", () => {
  // Even REST PATCH /issues/comments/{id} and POST /issues/{pr}/comments
  // return 503 on large PRs. The update and create must use GraphQL mutations:
  // updateIssueComment for updates, addComment for creates.
  assert.match(
    qaCommentStep,
    /mutation\s+Update\w*Comment.*updateIssueComment\s*\(\s*input\s*:\s*\{\s*id\s*:\s*\$id\s*,\s*body\s*:\s*\$body\s*\}\s*\)/s,
    "qa must update via GraphQL updateIssueComment mutation",
  );
  assert.match(
    qaCommentStep,
    /mutation\s+Create\w*Comment.*addComment\s*\(\s*input\s*:\s*\{\s*subjectId\s*:\s*\$subjectId\s*,\s*body\s*:\s*\$body\s*\}\s*\)/s,
    "qa must create via GraphQL addComment mutation",
  );
  assert.doesNotMatch(
    qaCommentStep,
    /github\.rest\.issues\.\w+Comment/,
    "qa must not use any github.rest.issues comment API (listComments, updateComment, createComment all 503 on large PRs)",
  );
});

test("pr-review preserves update-or-create behavior with GraphQL mutations", () => {
  // GraphQL discovery must still feed the update-or-create loop: if an
  // existing bot comment is found, update it via updateIssueComment;
  // otherwise create a new one via addComment.
  assert.match(
    prReviewCommentStep,
    /if\s*\(\s*botComment\s*\)\s*\{[\s\S]*?updateIssueComment[\s\S]*?\}\s*else\s*\{[\s\S]*?addComment/,
    "pr-review must keep the update-if-found-else-create branch structure with GraphQL mutations",
  );
});

test("qa preserves update-or-create behavior with GraphQL mutations", () => {
  assert.match(
    qaCommentStep,
    /if\s*\(\s*existing\s*\)\s*\{[\s\S]*?updateIssueComment[\s\S]*?\}\s*else\s*\{[\s\S]*?addComment/,
    "qa must keep the update-if-found-else-create branch structure with GraphQL mutations",
  );
});

test("neither comment-upsert step contains any REST issues comment API", () => {
  // Global prohibition: no github.rest.issues.* comment API may appear in
  // either comment-posting step — listComments, updateComment, and
  // createComment all hit REST endpoints that 503 on large PRs.
  assert.doesNotMatch(
    prReviewCommentStep,
    /github\.rest\.issues\.\w*Comment/,
    "pr-review comment step must not contain any github.rest.issues comment API",
  );
  assert.doesNotMatch(
    qaCommentStep,
    /github\.rest\.issues\.\w*Comment/,
    "qa comment step must not contain any github.rest.issues comment API",
  );
  // Also catch raw REST endpoints in embedded Python/shell (legacy qa path).
  assert.doesNotMatch(
    qaCommentStep,
    /gh\s+api\s+.*repos\/.*\/issues\/.*\/comments\b/,
    "qa comment step must not use gh api REST issues comments endpoint",
  );
  assert.doesNotMatch(
    qaCommentStep,
    /gh\s+api\s+.*issues\/comments\/.*-X.*PATCH/,
    "qa comment step must not use gh api REST PATCH issues comments endpoint",
  );
});
