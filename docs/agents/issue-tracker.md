# Issue tracker GitHub

本项目的任务与规格保存为 GitHub Issues。仓库为 `ulleo/SimpleNTSF`，使用 `gh` CLI；命令显式指定该仓库，避免与本地目录 SimpleNTFS 的拼写混淆。

## 常规操作

- 创建：`gh issue create --repo ulleo/SimpleNTSF --title "<title>" --body-file <file> --label <label>`。多行正文先写入临时文件，保留真实换行。
- 读取正文和评论：`gh issue view <number> --repo ulleo/SimpleNTSF --json number,title,body,labels,comments,state`。
- 列表：`gh issue list --repo ulleo/SimpleNTSF --state open --json number,title,body,labels`；按任务需要添加标签过滤及分页。
- 修改正文使用 `gh issue edit` 和 `--body-file`；评论使用 `gh issue comment` 和 `--body-file`。
- 标签使用 `gh issue edit` 的 `--add-label` 或 `--remove-label`，名称见 [triage-labels.md](triage-labels.md)。
- 技能要求发布任务时，创建 GitHub Issue；要求读取任务时，同时读取其正文和评论。

## 子任务与阻塞关系

按依赖顺序创建任务，先创建阻塞项。来源为现有 Issue 时，将新任务关联为其子任务；使用当前 CLI 支持的子任务操作，或 GitHub 子任务接口。发布拆分任务不关闭或修改父任务正文。

使用 GitHub 原生阻塞关系：
`gh api --method POST repos/ulleo/SimpleNTSF/issues/<child-number>/dependencies/blocked_by -F issue_id=<blocker-database-id>`。

阻塞任务的数据库 ID 用 `gh api repos/ulleo/SimpleNTSF/issues/<blocker-number> --jq .id` 获取；它不是 Issue 编号或 node ID。若仓库不支持原生依赖，在正文中记录 `Blocked by: #N, #M`。

只有所有阻塞任务均已完成，才可开始执行该任务。`ready-for-agent` 表示任务描述足够明确，不表示其依赖已经解除。

## Wayfinder

使用一个标记为 `wayfinder:map` 的 Issue 保存工作地图，将各任务关联为其子任务。子任务类型使用 `wayfinder:<type>`，例如 research、prototype、grilling、task。

执行前读取地图、任务和阻塞项，从未关闭、无未完成阻塞项且未被领取的任务中选择；领取时指派给执行者。完成后记录结果、关闭已完成任务，再按该技能约定更新地图。

## Pull requests as a triage surface

**PRs as a request surface: no.**
