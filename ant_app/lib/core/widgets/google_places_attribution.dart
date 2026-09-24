import 'package:flutter/material.dart';

/// Google's required attribution when Place Autocomplete predictions are
/// displayed outside a Google map surface.
class GooglePlacesAttribution extends StatelessWidget {
  const GooglePlacesAttribution({super.key});

  @override
  Widget build(BuildContext context) => RichText(
    text: const TextSpan(
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      children: [
        TextSpan(
          text: 'G',
          style: TextStyle(color: Color(0xFF4285F4)),
        ),
        TextSpan(
          text: 'o',
          style: TextStyle(color: Color(0xFFEA4335)),
        ),
        TextSpan(
          text: 'o',
          style: TextStyle(color: Color(0xFFFBBC05)),
        ),
        TextSpan(
          text: 'g',
          style: TextStyle(color: Color(0xFF4285F4)),
        ),
        TextSpan(
          text: 'l',
          style: TextStyle(color: Color(0xFF34A853)),
        ),
        TextSpan(
          text: 'e',
          style: TextStyle(color: Color(0xFFEA4335)),
        ),
      ],
    ),
  );
}
