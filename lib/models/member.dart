class Member {
  final String memberId;
  final String companyId;
  String fullName;
  String dateOfBirth;
  String address;
  String phone;
  String email;
  String identificationNumber;
  String identificationType;
  bool status; // true = active, false = inactive
  String notes;
  Map<String, dynamic>? certificate;
  String? issuedDate;

  Member({
    required this.memberId,
    required this.companyId,
    required this.fullName,
    this.dateOfBirth = '',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.identificationNumber = '',
    this.identificationType = '',
    this.status = true,
    this.notes = '',
    this.certificate,
    this.issuedDate,
  });

  factory Member.fromJson(Map<String, dynamic> json) {
    return Member(
      memberId: json['memberId'] ?? '',
      companyId: json['companyId'] ?? '',
      fullName: json['full_name'] ?? json['fullName'] ?? '',
      dateOfBirth: json['date_of_birth'] ?? json['dateOfBirth'] ?? '',
      address: json['address'] ?? '',
      phone: json['phone'] ?? '',
      email: json['email'] ?? '',
      identificationNumber: json['identification_number'] ?? '',
      identificationType: json['identification_type'] ?? '',
      status: _parseBool(json['status']),
      notes: json['notes'] ?? '',
      certificate: json['certificate'] as Map<String, dynamic>?,
      issuedDate: json['issued_date'] ?? json['issuedDate'],
    );
  }

  static bool _parseBool(dynamic value) {
    if (value == null) return true; // default active
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return true;
  }

  Map<String, dynamic> toJson() => {
        'memberId': memberId,
        'companyId': companyId,
        'full_name': fullName,
        'date_of_birth': dateOfBirth,
        'address': address,
        'phone': phone,
        'email': email,
        'identification_number': identificationNumber,
        'identification_type': identificationType,
        'status': status,
        'notes': notes,
      };

  Member copyWith({
    String? fullName,
    String? dateOfBirth,
    String? address,
    String? phone,
    String? email,
    String? identificationNumber,
    String? identificationType,
    bool? status,
    String? notes,
  }) {
    return Member(
      memberId: memberId,
      companyId: companyId,
      fullName: fullName ?? this.fullName,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      identificationNumber: identificationNumber ?? this.identificationNumber,
      identificationType: identificationType ?? this.identificationType,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      certificate: certificate,
      issuedDate: issuedDate,
    );
  }
}
