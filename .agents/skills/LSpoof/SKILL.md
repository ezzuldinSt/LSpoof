```markdown
# LSpoof Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the core development patterns and conventions used in the LSpoof TypeScript codebase. You'll learn about file naming, import/export styles, commit patterns, and how to structure and run tests. While no formal workflows or frameworks are detected, this guide will help you maintain consistency and quality in LSpoof projects.

## Coding Conventions

### File Naming
- **Use PascalCase** for all file names.
  - Example: `UserManager.ts`, `NetworkUtils.ts`

### Import Style
- **Use relative imports** for referencing other modules.
  - Example:
    ```typescript
    import { UserManager } from './UserManager';
    ```

### Export Style
- **Use named exports** for all modules.
  - Example:
    ```typescript
    // In UserManager.ts
    export function createUser(name: string) { ... }

    // In another file
    import { createUser } from './UserManager';
    ```

### Commit Patterns
- **Freeform commit messages** (no enforced prefixes).
- **Average length:** ~50 characters.
- Example:
  ```
  Add spoofing logic for new protocol version
  ```

## Workflows

### Creating a New Module
**Trigger:** When adding new functionality.
**Command:** `/new-module`

1. Create a new file using PascalCase (e.g., `FeatureName.ts`).
2. Use named exports for all functions, classes, or constants.
3. Use relative imports to reference other modules.
4. Write corresponding tests in a file named `FeatureName.test.ts`.

### Updating an Existing Module
**Trigger:** When modifying or extending existing logic.
**Command:** `/update-module`

1. Locate the module file (e.g., `FeatureName.ts`).
2. Make changes using the existing code style.
3. Update or add tests in `FeatureName.test.ts`.
4. Write a clear, concise commit message (~50 chars).

### Writing Tests
**Trigger:** When adding or updating features.
**Command:** `/write-test`

1. Create or update a test file matching `*.test.ts` pattern.
2. Write tests using the project's preferred (unknown) framework.
3. Use relative imports to bring in modules under test.
4. Run tests to verify correctness.

## Testing Patterns

- **Test files** are named with the pattern `*.test.ts` (e.g., `UserManager.test.ts`).
- **Testing framework** is not specified; follow existing patterns.
- **Import modules** under test using relative imports.
- Example:
  ```typescript
  import { createUser } from './UserManager';

  // Example test (framework-agnostic)
  test('creates a user', () => {
    const user = createUser('Alice');
    expect(user.name).toBe('Alice');
  });
  ```

## Commands
| Command        | Purpose                                   |
|----------------|-------------------------------------------|
| /new-module    | Create a new module following conventions |
| /update-module | Update an existing module                 |
| /write-test    | Add or update tests for a module          |
```
