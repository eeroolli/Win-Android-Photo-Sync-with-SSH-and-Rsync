# My Programming Preferences

## Clarity and Robustness
- Scripts and code should be robust, clear, and maintainable.
- Avoid fragile hacks—prefer explicit, well-documented logic, especially for file handling and parsing (e.g., use `csvtool` for CSVs, not `awk` or `read`).

## Absolute Paths for Critical Files
- All important files (logs, CSVs, hash databases) should use absolute paths, not relative ones, to avoid ambiguity and ensure scripts work regardless of the current working directory.

## Centralized Configuration
- All scripts in one project should source a single config file. For example (`config.conf`) for paths, log locations, and other settings.
- in some situations it is better to use [project_name].conf instead.
- No hardcoded paths in scripts — everything should be configurable.

## Consistent Naming and Terminology
- Use clear, consistent terminology. For example:
  - "copy" for device-to-computer actions/logs
  - "import" for Lightroom actions
  - Folder `/imported_to_lightroom` (not `/kopiert`)

## Incremental and Efficient Workflows
- Scripts should be incremental and efficient—avoid reprocessing or rehashing files unnecessarily.
- Use persistent hash databases and only update as needed.

## Safe Operations
- Deletion scripts must be safe: only delete files that are provably imported (by hash, not just name).
- Always prompt for confirmation before destructive actions.

## Comprehensive Logging
- Maintain both human-readable summary logs and detailed CSV logs for all operations.
- Logs should be year-based for easy rotation and review.

## Tooling
- Use standard GNU/Linux tools. If a non-standard tool is required (like `csvtool`), document its installation and usage clearly.

## Editor/Environment
- I use UltraEdit, which creates `.bak` files—these should be ignored by Git and not tracked.

## Commit Messages
- Use project-wide prefixes in commit messages for consistency:
  - `fix:`, `debug:`, `feature:`, `minor:`, etc.

## Documentation
- Keep documentation up to date with the codebase, especially when changing workflows, file names, or conventions. 
- Keep the comments and documentation in the code simple and clean. Code should be readable without comments, too. 

## Best Practices
- I want to use best practices as much as possible.  

## Guidance
- Try to guide me to use best practices for security, robustness, testing, formating, maintainence.  
- I want to learn things. You role is also to be a mentor, who points out when I am not using best practices and teaches me how to improve my code. 
- I want to use the best tools to solve the right problems. In every project, or new chat, pay attention what is the problem we are trying to solve. Are we choosing the best approach or are we complicating things unnessasary.
