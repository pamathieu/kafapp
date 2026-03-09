import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../models/member.dart';

class ApiService {
  static const String _baseUrl   = 'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';
  static const String _region    = 'us-east-1';
  static const String _service   = 'execute-api';
  static const String _companyId = 'KAFA-001';

  final String  _accessKeyId;
  final String  _secretAccessKey;
  final String? _sessionToken;

  ApiService({
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
  })  : _accessKeyId     = accessKeyId,
        _secretAccessKey = secretAccessKey,
        _sessionToken    = sessionToken;

  // ── SigV4 helpers ────────────────────────────────────────────────────────────

  List<int> _hmacSha256Bytes(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _sha256Hex(String data) =>
      sha256.convert(utf8.encode(data)).toString();

  String _pad(int v, int w) => v.toString().padLeft(w, '0');

  Map<String, String> _signRequest({
    required String method,
    required Uri    uri,
    required String body,
  }) {
    final now        = DateTime.now().toUtc();
    final datestamp  = _pad(now.year, 4) + _pad(now.month, 2) + _pad(now.day, 2);
    final amzdate    = '${datestamp}T${_pad(now.hour, 2)}${_pad(now.minute, 2)}${_pad(now.second, 2)}Z';
    final bodyHash   = _sha256Hex(body);
    final host       = uri.host;

    final signingHeaders = <String, String>{
      'host':                 host,
      'x-amz-date':           amzdate,
      'x-amz-content-sha256': bodyHash,
      if (_sessionToken != null) 'x-amz-security-token': _sessionToken!,
      if (body.isNotEmpty) 'content-type': 'application/json',
    };

    final sortedKeys       = signingHeaders.keys.toList()..sort();
    final canonicalHeaders = sortedKeys.map((k) => '$k:${signingHeaders[k]}\n').join();
    final signedHeaders    = sortedKeys.join(';');

    final sortedParams = uri.queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final queryString = sortedParams
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final canonicalRequest = [
      method,
      uri.path,
      queryString,
      canonicalHeaders,
      signedHeaders,
      bodyHash,
    ].join('\n');

    final credentialScope = '$datestamp/$_region/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzdate,
      credentialScope,
      _sha256Hex(canonicalRequest),
    ].join('\n');

    final signingKey = [datestamp, _region, _service, 'aws4_request'].fold(
      utf8.encode('AWS4$_secretAccessKey') as List<int>,
      (prev, part) => _hmacSha256Bytes(prev, part),
    );

    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();

    final authHeader =
        'AWS4-HMAC-SHA256 Credential=$_accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    // DEBUG — print to browser console
    print('=== SigV4 DEBUG ===');
    print('Method: $method');
    print('URI: $uri');
    print('AMZ Date: $amzdate');
    print('Body hash: $bodyHash');
    print('Canonical headers:\n$canonicalHeaders');
    print('Signed headers: $signedHeaders');
    print('Canonical request:\n$canonicalRequest');
    print('String to sign:\n$stringToSign');
    print('Auth header: $authHeader');
    print('Access key ID (first 8): ${_accessKeyId.substring(0, 8)}...');
    print('===================');

    return {
      'Authorization':         authHeader,
      'x-amz-date':            amzdate,
      'x-amz-content-sha256':  bodyHash,
      if (_sessionToken != null) 'x-amz-security-token': _sessionToken!,
      if (body.isNotEmpty) 'content-type': 'application/json',
    };
  }

  // ── API calls ────────────────────────────────────────────────────────────────

  Future<List<Member>> listMembers() async {
    final uri      = Uri.parse('$_baseUrl/members/list?companyId=$_companyId');
    final headers  = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List membersJson = data['members'] ?? [];
      return membersJson.map((m) => Member.fromJson(m)).toList();
    }
    throw Exception('Failed to load members: ${response.statusCode} ${response.body}');
  }

  Future<Member> getMember(String memberId) async {
    final uri      = Uri.parse('$_baseUrl/members?memberId=$memberId&companyId=$_companyId');
    final headers  = _signRequest(method: 'GET', uri: uri, body: '');
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return Member.fromJson(json.decode(response.body));
    }
    throw Exception('Member not found');
  }

  Future<Member> editMember(String memberId) async {
    final uri      = Uri.parse('$_baseUrl/members/edit');
    final body     = json.encode({'memberId': memberId, 'companyId': _companyId});
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return Member.fromJson(data['member'] ?? data);
    }
    throw Exception('Failed to load member for editing');
  }

  Future<Member> updateMember(Member member) async {
    final uri  = Uri.parse('$_baseUrl/members/update');
    final body = json.encode({
      'memberId':              member.memberId,
      'companyId':             _companyId,
      'full_name':             member.fullName,
      'date_of_birth':         member.dateOfBirth,
      'address':               member.address,
      'phone':                 member.phone,
      'email':                 member.email,
      'identification_number': member.identificationNumber,
      'identification_type':   member.identificationType,
      'status':                member.status,
      'notes':                 member.notes,
    });
    final headers  = _signRequest(method: 'POST', uri: uri, body: body);
    final response = await http.post(uri, headers: headers, body: body);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return Member.fromJson(data['member'] ?? data);
    }
    throw Exception('Failed to update member: ${response.statusCode}');
  }
}