import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  /// Firebase UID is the canonical user ID
  final String uid;
  final String name;
  final String email;
  final String? profileImage;
  final String? phone;
  final String? bio;
  final bool isOnline;
  final DateTime? lastSeen;
  final DateTime? createdAt;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.profileImage,
    this.phone,
    this.bio,
    this.isOnline = false,
    this.lastSeen,
    this.createdAt,
  });

  /// Convert to Firestore Map for writing to users/{uid}
  Map<String, dynamic> toFirestore() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'profileImage': profileImage,
      'phone': phone,
      'bio': bio,
      'isOnline': isOnline,
      'lastSeen': lastSeen != null
          ? Timestamp.fromDate(lastSeen!)
          : FieldValue.serverTimestamp(),
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
    };
  }

  /// Alias for toFirestore
  Map<String, dynamic> toMap() => toFirestore();

  /// Create UserModel from Firestore DocumentSnapshot
  factory UserModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return UserModel.fromMap(data, doc.id);
  }

  /// Create UserModel from Map
  factory UserModel.fromMap(Map<String, dynamic> map, String docId) {
    return UserModel(
      uid: map['uid'] ?? docId,
      name: map['name'] ?? map['displayName'] ?? 'User',
      email: map['email'] ?? '',
      profileImage: map['profileImage'] ?? map['photoUrl'],
      phone: map['phone'],
      bio: map['bio'],
      isOnline: map['isOnline'] ?? false,
      lastSeen: map['lastSeen'] is Timestamp
          ? (map['lastSeen'] as Timestamp).toDate()
          : (map['lastSeen'] != null
              ? DateTime.tryParse(map['lastSeen'].toString())
              : null),
      createdAt: map['createdAt'] is Timestamp
          ? (map['createdAt'] as Timestamp).toDate()
          : (map['createdAt'] != null
              ? DateTime.tryParse(map['createdAt'].toString())
              : null),
    );
  }

  UserModel copyWith({
    String? uid,
    String? name,
    String? email,
    String? profileImage,
    String? phone,
    String? bio,
    bool? isOnline,
    DateTime? lastSeen,
    DateTime? createdAt,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      profileImage: profileImage ?? this.profileImage,
      phone: phone ?? this.phone,
      bio: bio ?? this.bio,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
