typedef Json = Map<String, Object?>;

const difficulties = ['Easy', 'Medium', 'Hard', 'Expert'];
const devTypes = ['Manual', 'Assisted'];
const statuses = ['idea', 'doing', 'completed'];
const statusLabel = {'idea': 'Idea', 'doing': 'Doing', 'completed': 'Completed'};

/// The fields a project change may carry (server/index.js PROJECT_FIELDS).
const projectFields = ['name', 'description', 'difficulty', 'dev_type', 'status', 'link', 'has_content', 'notes'];

/// A project as the screens see it: the server's row with this phone's queued changes on top.
class Project {
  const Project(this.row);
  final Json row;

  String get id => row['id'] as String;
  String get name => row['name'] as String? ?? '';
  String? get description => row['description'] as String?;
  String get difficulty => difficulties.contains(row['difficulty']) ? row['difficulty'] as String : 'Medium';
  String get devType => devTypes.contains(row['dev_type']) ? row['dev_type'] as String : 'Assisted';
  String get status => statuses.contains(row['status']) ? row['status'] as String : 'idea';
  String? get link => row['link'] as String?;
  bool get hasContent => row['has_content'] == true;
  String? get notes => row['notes'] as String?;
  String? get createdAt => row['created_at'] as String?;
  String? get updatedAt => row['updated_at'] as String?;
  List<String> get categoryIds => [for (final c in row['categoryIds'] as List? ?? const []) c as String];

  /// Changed on this phone and not confirmed by the server yet.
  bool get pending => row['pending'] == true;
}

class Category {
  const Category(this.row);
  final Json row;
  String get id => row['id'] as String;
  String get name => row['name'] as String? ?? '';
}

/// Names sorted the way people read them: case doesn't matter, then exact text breaks ties.
int byName(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : a.compareTo(b);
}
