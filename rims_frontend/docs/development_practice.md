# RIMS Frontend Development Practice

## Architecture

Use feature-first MVVM with Repository and a lightweight Domain layer.

Normal flow:

```text
Page -> ViewModel -> UseCase -> Repository -> DataSource -> ApiClient / Storage
```

For simple CRUD, `Page -> ViewModel -> Repository` is acceptable.

## Naming

| Kind | Rule | Example |
| --- | --- | --- |
| Class | UpperCamelCase | `MyHomePage` |
| Function | lowerCamelCase | `getData` |
| Variable | lowerCamelCase | `userName` |
| Constant | `k` prefix + UpperCamelCase | `kMaxCount` |
| File | lowercase with underscores | `my_home_page.dart` |

## Boundaries

- Pages render UI and forward user actions to ViewModels.
- ViewModels own presentation state.
- Repositories are feature data boundaries.
- DataSources own remote or local data mechanics.
- `ApiClient` owns Dio configuration and request helpers.
- App-wide events use `AppEventBus` only for cross-module events.

## Testing

Prioritize tests for:

- Result and failure behavior.
- API exception mapping.
- Repository behavior.
- UseCase behavior.
- ViewModel state transitions.
