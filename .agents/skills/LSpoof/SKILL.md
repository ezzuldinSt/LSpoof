```markdown
# LSpoof Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you how to contribute to the LSpoof TypeScript codebase by following its established coding conventions, file organization, and testing patterns. You'll learn how to name files, structure imports/exports, and write tests in a way that maintains consistency and readability across the project.

## Coding Conventions

### File Naming
- Use **PascalCase** for filenames.
  - Example: `MyComponent.ts`, `UserService.ts`

### Import Style
- Use **relative imports** for referencing other modules.
  - Example:
    ```typescript
    import { UserService } from './UserService';
    ```

### Export Style
- Use **named exports** instead of default exports.
  - Example:
    ```typescript
    // UserService.ts
    export function getUser() { ... }
    ```

### Commit Patterns
- Commit messages are freeform, with no strict prefixing.
- Average commit message length: ~49 characters.

## Workflows

### Adding a New Module
**Trigger:** When you need to add a new feature or utility.
**Command:** `/add-module`

1. Create a new file using PascalCase (e.g., `NewFeature.ts`).
2. Use named exports for all functions, classes, or constants.
3. Use relative imports to reference other modules.
4. Write corresponding test file as `NewFeature.test.ts`.

### Writing a Test
**Trigger:** When you need to test a module or function.
**Command:** `/write-test`

1. Create a test file with the pattern `*.test.ts` (e.g., `UserService.test.ts`).
2. Write test cases using the project's preferred (but currently undetected) testing framework.
3. Use relative imports to bring in the module under test.

### Refactoring Code
**Trigger:** When updating or improving existing code.
**Command:** `/refactor`

1. Update the relevant `.ts` files, maintaining PascalCase naming.
2. Ensure all imports remain relative and exports are named.
3. Update or add tests as needed in corresponding `*.test.ts` files.

## Testing Patterns

- Test files use the pattern `*.test.ts`.
- The specific testing framework is undetected, but tests should be written in TypeScript and placed alongside or near the modules they test.
- Example:
  ```typescript
  // UserService.test.ts
  import { getUser } from './UserService';

  describe('getUser', () => {
    it('should return user data', () => {
      // test implementation
    });
  });
  ```

## Commands
| Command        | Purpose                                   |
|----------------|-------------------------------------------|
| /add-module    | Scaffold a new module with conventions    |
| /write-test    | Create a test file for a module/function  |
| /refactor      | Refactor code while following conventions |
```
