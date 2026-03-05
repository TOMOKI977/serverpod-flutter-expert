---
title: Database Design Reference
description: Comprehensive guide to Serverpod 3.4.x database models, relationships, indexes, migrations, and ORM queries.
tags: [serverpod, database, orm, migrations, postgresql, models, spy-yaml]
---

# Database Design in Serverpod 3.4.x

Serverpod uses `.spy.yaml` files to define the data model. These generate Dart classes, PostgreSQL migrations, and a type-safe ORM. Always run `dart run serverpod_cli generate` after changes.

---

## 1. Model Field Types

| YAML Type | Dart Type | PostgreSQL Type |
|-----------|-----------|-----------------|
| `int` | `int` | `BIGINT` |
| `double` | `double` | `DOUBLE PRECISION` |
| `bool` | `bool` | `BOOLEAN` |
| `String` | `String` | `TEXT` |
| `DateTime` | `DateTime` | `TIMESTAMP WITH TIME ZONE` |
| `ByteData` | `ByteData` | `BYTEA` |
| `Map<String, dynamic>` | `Map<String, dynamic>` | `JSONB` |
| `List<T>` | `List<T>` | `JSONB` |
| Custom class | `MyClass` | Serialized to `JSONB` |
| Enum | `MyEnum` | `TEXT` (when `serialized: byName`) |

Append `?` to make any field nullable.

---

## 2. Model Definition Examples

### Basic Model

```yaml
# lib/src/models/product.spy.yaml
class: Product
table: products
fields:
  name: String
  description: String?
  priceCents: int
  stock: int, default=0
  isActive: bool, default=true
  tags: List<String>?                  # JSON array
  metadata: Map<String, dynamic>?      # JSONB blob
  createdAt: DateTime
  updatedAt: DateTime
indexes:
  products_name_idx:
    fields: name
  products_active_idx:
    fields: isActive
```

### Enum Definition

```yaml
# lib/src/models/order_status.spy.yaml
enum: OrderStatus
serialized: byName      # Stored as 'pending', 'paid', etc. (not 0,1,2)
values:
  - pending
  - paid
  - processing
  - shipped
  - delivered
  - cancelled
  - refunded
```

### Model Using Enum + JSON + Composite Index

```yaml
# lib/src/models/order.spy.yaml
class: Order
table: orders
fields:
  userId: int
  status: OrderStatus
  lineItems: List<Map<String, dynamic>>   # JSON array of {productId, qty, priceCents}
  shippingAddress: Map<String, dynamic>?
  totalCents: int
  notes: String?
  createdAt: DateTime
  updatedAt: DateTime
indexes:
  orders_user_status_idx:
    fields: userId, status         # Composite index for common query pattern
  orders_status_created_idx:
    fields: status, createdAt
  orders_user_created_idx:
    fields: userId, createdAt
```

---

## 3. Relationships

### One-to-Many

```yaml
# lib/src/models/author.spy.yaml
class: Author
table: authors
fields:
  name: String
  email: String
  bio: String?
indexes:
  authors_email_idx:
    fields: email
    unique: true
```

```yaml
# lib/src/models/book.spy.yaml
class: Book
table: books
fields:
  authorId: int          # Foreign key to authors.id
  title: String
  isbn: String
  publishedYear: int?
indexes:
  books_author_idx:
    fields: authorId
  books_isbn_idx:
    fields: isbn
    unique: true
```

Query books by author:
```dart
final books = await Book.db.find(
  session,
  where: (t) => t.authorId.equals(authorId),
  orderBy: (t) => t.title,
);
```

### Many-to-Many (Junction Table)

```yaml
# lib/src/models/tag.spy.yaml
class: Tag
table: tags
fields:
  name: String
  slug: String
indexes:
  tags_slug_idx:
    fields: slug
    unique: true
```

```yaml
# lib/src/models/book_tag.spy.yaml
class: BookTag
table: book_tags
fields:
  bookId: int
  tagId: int
indexes:
  book_tags_unique_idx:
    fields: bookId, tagId
    unique: true
  book_tags_tag_idx:
    fields: tagId
```

Query tags for a book (manual join):
```dart
Future<List<Tag>> getTagsForBook(Session session, int bookId) async {
  final bookTags = await BookTag.db.find(
    session,
    where: (t) => t.bookId.equals(bookId),
  );
  if (bookTags.isEmpty) return [];

  final tagIds = bookTags.map((bt) => bt.tagId).toList();
  return await Tag.db.find(
    session,
    where: (t) => t.id.inSet(tagIds.toSet()),
  );
}
```

---

## 4. Indexes and Performance

### Index Types

```yaml
indexes:
  # Single column — default btree
  orders_created_idx:
    fields: createdAt

  # Unique constraint
  users_email_idx:
    fields: email
    unique: true

  # Composite — order of fields matters for query planner
  orders_user_status_idx:
    fields: userId, status    # Efficient for: WHERE userId=? AND status=?

  # Composite unique
  memberships_unique_idx:
    fields: userId, teamId
    unique: true
```

### Index Strategy
- Put high-cardinality, frequently-filtered columns first in composite indexes.
- Avoid indexing boolean columns alone — composite indexes are better.
- Review slow queries with `EXPLAIN ANALYZE` in PostgreSQL.
- Each index has a write overhead; don't over-index.

---

## 5. Complex ORM Queries

```dart
// ── Pagination ────────────────────────────────────────────────────────────────
Future<(List<Order>, int)> getOrdersPage(
  Session session,
  int userId, {
  int page = 0,
  int pageSize = 20,
}) async {
  final where = (OrderTable t) => t.userId.equals(userId);
  final orders = await Order.db.find(
    session,
    where: where,
    orderBy: (t) => t.createdAt,
    orderDescending: true,
    limit: pageSize,
    offset: page * pageSize,
  );
  final total = await Order.db.count(session, where: where);
  return (orders, total);
}

// ── Multiple conditions ───────────────────────────────────────────────────────
final pendingOrders = await Order.db.find(
  session,
  where: (t) =>
      t.userId.equals(userId) &
      (t.status.equals(OrderStatus.pending) | t.status.equals(OrderStatus.processing)) &
      t.createdAt.greaterThan(DateTime.now().subtract(const Duration(days: 30))),
);

// ── NULL checks ───────────────────────────────────────────────────────────────
final unshipped = await Order.db.find(
  session,
  where: (t) => t.shippingAddress.isNull(),
);

// ── LIKE / pattern matching ───────────────────────────────────────────────────
final books = await Book.db.find(
  session,
  where: (t) => t.title.ilike('%dart%'), // case-insensitive LIKE
);

// ── IN set ────────────────────────────────────────────────────────────────────
final selectedBooks = await Book.db.find(
  session,
  where: (t) => t.id.inSet({1, 2, 3, 4, 5}),
);

// ── Batch insert ──────────────────────────────────────────────────────────────
final tags = await Tag.db.insert(session, [
  Tag(name: 'Flutter', slug: 'flutter'),
  Tag(name: 'Dart', slug: 'dart'),
  Tag(name: 'Backend', slug: 'backend'),
]);

// ── Batch update ──────────────────────────────────────────────────────────────
final toUpdate = orders.map((o) => o.copyWith(status: OrderStatus.processing)).toList();
await Order.db.update(session, toUpdate);

// ── Delete where ──────────────────────────────────────────────────────────────
final deleted = await Order.db.deleteWhere(
  session,
  where: (t) => t.status.equals(OrderStatus.cancelled) &
      t.updatedAt.lessThan(DateTime.now().subtract(const Duration(days: 365))),
);
```

---

## 6. Transactions

```dart
// All-or-nothing: if any step throws, all changes are rolled back
await session.db.transaction((tx) async {
  // 1. Create order
  final order = await Order.db.insertRow(
    session,
    Order(
      userId: userId,
      status: OrderStatus.pending,
      totalCents: totalCents,
      lineItems: lineItems,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ),
    transaction: tx,
  );

  // 2. Decrement stock for each line item
  for (final item in lineItems) {
    final product = await Product.db.findById(
      session,
      item['productId'] as int,
      transaction: tx,
    );
    if (product == null) throw NotFoundException('Product not found');
    if (product.stock < (item['qty'] as int)) {
      throw Exception('Insufficient stock for ${product.name}');
    }
    await Product.db.updateRow(
      session,
      product.copyWith(stock: product.stock - (item['qty'] as int)),
      transaction: tx,
    );
  }

  return order;
});
```

---

## 7. Migrations

```bash
# After model change: generate Dart code
dart run serverpod_cli generate

# Create migration SQL
dart run serverpod_cli create-migration

# List all migrations
dart run serverpod_cli migrations list

# Apply (development)
dart run bin/main.dart --apply-migrations

# Apply (production)
dart run bin/main.dart --mode production --apply-migrations

# Roll back last migration (development only)
dart run serverpod_cli migrations rollback
```

### Migration File Anatomy

Generated migrations live in `migrations/<timestamp>_<name>/`. Each contains:
- `definition.yaml` — full schema at this point in history
- `definition.sql` — SQL to apply
- `rollback.sql` — SQL to undo

**Never edit migration files manually.** If you need to fix something, create a new migration.

### Renaming a Column Safely

1. Add the new column to the model.
2. Run `serverpod generate` and `create-migration`.
3. Write a data migration script to copy data from old column to new.
4. Remove the old column in a subsequent migration.

---

## 8. JSON Fields

```dart
// Store arbitrary JSON
final profile = UserProfile(
  userId: 1,
  metadata: {
    'preferences': {'theme': 'dark', 'language': 'en'},
    'onboardingStep': 3,
  },
);
await UserProfile.db.insertRow(session, profile);

// Read JSON field
final saved = await UserProfile.db.findFirstRow(
  session,
  where: (t) => t.userId.equals(1),
);
final theme = saved?.metadata?['preferences']?['theme'] as String?;
```

> Note: JSON fields cannot be queried by their contents via the ORM. For filterable JSON properties, model them as dedicated columns.

---

## 9. Best Practices

- Use `createdAt` / `updatedAt` on every table; set them in endpoint logic, not triggers.
- Always use `DateTime.now().toUtc()` to avoid timezone bugs.
- Prefer specific column indexes over full-table scans for large tables.
- Keep models simple — avoid deeply nested JSON; model as separate tables when querying is needed.
- Run `dart analyze` after generating to catch type mismatches early.
