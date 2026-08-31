# Crime Module Implementation Plan (ANT)

This document outlines the concrete, step-by-step engineering plan to build the Contextual Crime & Safety Module ($w_1$) for the ANT application. It details how we will extract unstructured data from official police reports and convert it into a robust, low-latency routing factor.

## The Reality of Official Police Reports
We will make use of the official Dhaka Metropolitan Police (DMP) reports. Because they are in PDF format, we cannot query them in real-time while a user is walking. We will decouple the *Data Ingestion* phase from the *App Navigation* phase using an automated pipeline. 

---

## Step 1: The Automated Data Ingestion Pipeline (Cloud)
*Goal: Automatically turn new PDF documents into a structured database.*

1. **Automated Scraping:** We will deploy a Python web scraper (using BeautifulSoup) on a cron job via **Google Cloud Functions**. Once a week, it will check the DMP website for newly uploaded crime statistic PDFs.
2. **Extraction (OCR & NLP):** 
   - When a new PDF is detected, the Cloud Function downloads it and passes it to **Google Document AI** to parse the unstructured tables. 
   - A secondary LLM pass extracts specific street-level crimes relevant to pedestrians (e.g., Mugging, Snatching, Robbery) and ignores irrelevant crimes (e.g., Cybercrime).
3. **Structuring:** The pipeline outputs a clean JSON payload formatted by **Thana** (Police Station jurisdiction) and the total count of street crimes for that period.

## Step 2: Geospatial Mapping (The "Thana" Polygons)
*Goal: Map crime statistics to physical coordinates on a map.*

1. We will use a **GeoJSON** file of Dhaka City that defines the exact geographic polygons (latitude/longitude boundaries) for every Thana.
2. The automated pipeline merges the newly extracted crime data with the GeoJSON. Every Thana polygon receives an updated static `Crime_Score` (from 1 to 10), normalized based on crime frequency and population density.

## Step 3: Backend Decision Engine (Firebase)
*Goal: Host the safety map and serve it to the ANT mobile app.*

1. **Database:** We will host the merged GeoJSON file on **Firebase Firestore**. Firebase is chosen for its excellent mobile SDKs, offline persistence, and real-time scaling capabilities.
2. **API Endpoint:** We will use **Firebase Cloud Functions** to expose an endpoint called `/check-route-safety`.
3. **Time-of-Day Weighting:** The Cloud Function will apply a temporal multiplier. A Thana might have a `Crime_Score` of 4 during the day, but the backend will multiply this score if the user is traveling between 10:00 PM and 5:00 AM, turning it into a high-risk zone at night.

## Step 4: Frontend App Integration (The Routing Logic)
*Goal: Prevent the user from walking through high-risk zones.*

1. **Request Route:** The user requests a route via voice or text. The ANT app requests standard directions from the Google Maps Directions API.
2. **Safety Check:** Google Maps returns a "polyline" (the physical path). Before showing this to the user, ANT sends the polyline to our `/check-route-safety` Cloud Function.
3. **Intersection Math:** The backend checks if the route's polyline intersects with any Thana polygons that have a `Crime_Score` above a dangerous threshold (e.g., > 7).
4. **Adaptive Rerouting:**
   - If the route is **Safe**, ANT begins navigation.
   - If the route is **Unsafe** (crosses a red zone), ANT requests an alternative route from Google Maps, explicitly adding "avoid" waypoints around the dangerous Thana.
   - The AI Assistant notifies the user: *"I have adjusted your route to avoid historically unsafe areas for your security."*
