library(shiny)
library(DT)
library(dplyr)
library(bslib)
library(bsicons)
library(httr)
library(jsonlite)
library(readxl)

# Define UI with dark mode switch and theme selector
ui <- page_navbar(
  theme = bs_theme(bootswatch = "flatly"),  # Default theme
  title = tags$span(
    tags$img(
      src = "logo.jpeg",
      width = "46px",
      height = "auto",
      class = "me-3"
    ),
    "Synthetic Data Generator with OpenAI"
  ),
  nav_spacer(), # push nav items to the right
  nav_item(input_dark_mode(id = "dark_mode", mode = "dark")),
  
  sidebar=sidebar(
    actionButton("config", "Enter API Key", icon = icon("link", lib = "glyphicon")),
    textInput("description", "Description (optional)", placeholder = "e.g., Windows event logs"),
    selectizeInput("input_field", "Input Field Name", choices = NULL, multiple = TRUE, options = list(create = TRUE)),
    numericInput("max_tokens", "Max Tokens", value = 10),
    actionButton("generate_data", "Generate Data", icon = icon("equalizer",lib = "glyphicon"), class = "btn-info"),
    actionButton("clear_table", "Clear Fields", icon = icon('broom'), class = "btn-info"),
    fileInput("data_file", "Upload a CSV or Excel File", 
              accept = c(".csv", ".xlsx")),
    
    # theme picker
    selectInput("theme", "Select Theme", choices = c("Flatly", "Minty", "Darkly", "Cyborg", "Journal", "Litera", "Lux", "Materia", "Pulse", "Sandstone", "Simplex", "Sketchy", "Slate", "Solar", "Spacelab", "Superhero", "United", "Yeti")),
    
    # OpenAI model selection
    selectInput("model", "Select Model", choices = c("gpt-4o-mini", "gpt-4o"))
  ),
  
  verbatimTextOutput("fields_to_gen"),
  card(
    title = "Generated Data",
    status = "info",
    width = 12,
    solidHeader = TRUE,
    collapsible = TRUE,
    collapsed = TRUE,
    dataTableOutput("generated_data")
  ),
  accordion(open = FALSE, 
            accordion_panel(
              title = "Debug Info", icon = bs_icon("bug-fill"),
              verbatimTextOutput("debug_output")
            )
  )
)

server <- function(input, output, session) {
  
  observe({
    theme <- input$theme
    bs_theme <- bs_theme(bootswatch = tolower(theme))
    session$setCurrentTheme(bs_theme)
  })
  
  fields <- reactiveVal(data.frame(Field = character(), stringsAsFactors = FALSE))
  
  observe({
    new_fields <- input$input_field
    if (!is.null(new_fields) && !identical(new_fields, fields()$Field)) {
      fields(data.frame(Field = new_fields, stringsAsFactors = FALSE))
    }
  })
  
  output$fields_to_gen <- renderText({
    paste("Fields to generate data:", paste(fields()$Field, collapse = ", "))
  })
  
  observeEvent(input$clear_table, {
    fields(data.frame(Field = character(), stringsAsFactors = FALSE))
  })
  
  api_key <- reactiveVal(NULL)
  
  observeEvent(input$config, {
    showModal(modalDialog(
      title = "API Key Configuration",
      passwordInput("api_key", "Enter your OpenAI API key:", value = api_key()),
      footer = tagList(
        actionButton("save", "Save", icon = icon("check", lib = "glyphicon"), style = "color: #fff; background-color: #5cb85c; border-color: #4cae4c;"),
        modalButton("Close", icon = icon("remove", lib = "glyphicon"))
      ),
      easyClose = TRUE
    ))
  })
  
  observeEvent(input$save, {
    if (is.null(input$api_key) || input$api_key == "") {
      showNotification("Please enter an API key before saving.", type = "warning")
    } else {
      api_key(input$api_key)
      removeModal()
      output$debug_output <- renderText({
        paste("API Key:", api_key())
      })
      showNotification("API Key Added", type = "message")
    }
  })
  
  # Process uploaded file
  observeEvent(input$data_file, {
    req(input$data_file)
    
    # Read the uploaded file
    ext <- tools::file_ext(input$data_file$name)
    if (ext == "csv") {
      data <- read.csv(input$data_file$datapath, stringsAsFactors = FALSE)
    } else if (ext == "xlsx") {
      data <- read_excel(input$data_file$datapath)
    } else {
      showNotification("Unsupported file type. Please upload a CSV or Excel file.", type = "error")
      return(NULL)
    }
    
    # Detect column names and data types
    column_info <- lapply(data, function(column) {
      class(column)[1]
    })
    
    # Update the fields input with column names
    updateSelectizeInput(session, "input_field", choices = names(column_info), selected = names(column_info))
  })
  
  observeEvent(input$generate_data, {
    if (is.null(api_key()) || api_key() == "") {
      showNotification("Please enter a valid OpenAI API key", type = "warning")
    } else {
      req(api_key())
      showNotification("Preparing to make API request...", type = "message")
      
      description <- ifelse(is.null(input$description) || input$description == "", 
                            "No specific description provided.", 
                            input$description)
      
      # Get fields and their detected data types
      selected_fields <- fields()$Field
      request_body <- list(
        model = input$model, 
        messages = list(
          list(role = "system", content = "You are a data generation tool."),
          list(role = "user", content = paste(
            paste0("Generate ", input$max_tokens, " rows of data."),
            if (!is.null(description) && description != "") {
              paste("--", "Description of the data context:", description)
            } else "",
            "--", "In addition to the data being generated, include data generated for the fields:", paste(selected_fields, collapse = ", "),
            "Return the data in comma-separated format using the fields as headers. Do not return anything other than the data. Do not include commas within data strings."
          ))
        )
      )
      
      print(request_body)
      
      output$debug_output <- renderText({
        paste("Request Body:", toJSON(request_body, auto_unbox = TRUE))
      })
      
      response <- tryCatch({
        POST(
          url = "https://api.openai.com/v1/chat/completions",
          add_headers(Authorization = paste("Bearer", api_key())),
          content_type_json(),
          body = toJSON(request_body, auto_unbox = TRUE)
        )
      }, error = function(e) {
        output$debug_output <- renderText({
          paste("Error in API request:", e$message)
        })
        showNotification("Error in API request. Please check your API key and try again.", type = "error")
        NULL
      })
      
      if (!is.null(response)) {
        response_status <- http_status(response)$category
        response_content <- content(response, "text", encoding = "UTF-8")
        
        output$debug_output <- renderText({
          paste("HTTP status:", response_status, "\nRaw API response:", response_content)
        })
        
        if (response_status == "Success") {
          result <- tryCatch({
            fromJSON(response_content, simplifyVector = FALSE)
          }, error = function(e) {
            output$debug_output <- renderText({
              paste("Error in parsing response:", e$message)
            })
            showNotification("Error parsing response. Please check the format of the response.", type = "error")
            NULL
          })
          
          if (!is.null(result)) {
            if ("choices" %in% names(result) && length(result$choices) > 0) {
              synthetic_data <- result$choices[[1]]$message$content
              
              synthetic_df_parsed <- tryCatch({
                read.csv(text = synthetic_data, header = TRUE, stringsAsFactors = FALSE)
              }, warning = function(w) {
                output$debug_output <- renderText({
                  paste("Warning during CSV parsing:", w$message)
                })
                showNotification("Warning during CSV parsing. Some data may not have been parsed correctly.", type = "warning")
                NULL
              }, error = function(e) {
                output$debug_output <- renderText({
                  paste("Error during CSV parsing:", e$message)
                })
                showNotification("Error parsing response. Please check the format of the response and try again.", type = "error")
                NULL
              })
              
              if (!is.null(synthetic_df_parsed)) {
                output$generated_data <- renderDataTable({
                  datatable(synthetic_df_parsed, extensions = c('Buttons', 'ColReorder'), 
                            options = list(
                              dom = 'Bfrtip',
                              buttons = c('copy', 'csv', 'excel', 'pdf'),
                              colReorder = TRUE,
                              fixedHeader = FALSE,
                              deferRender = TRUE,
                              scrollY = 400,
                              pageLength = 10)
                  )
                })
                
                output$debug_output <- renderText({
                  "API request successful. Data rendered as a DataTable."
                })
                
                showNotification("Synthetic data generated successfully!", type = "message")
              }
            } else {
              output$debug_output <- renderText({
                paste("API request successful but no valid 'choices' field in response. Parsed response:", toString(result))
              })
              showNotification("API response received but no valid data was returned.", type = "warning")
            }
          }
        }
      }
    }
  })
  
  is_daytime <- function() {
    current_time <- as.POSIXlt(Sys.time(), tz = Sys.timezone())
    hour <- current_time$hour
    return(hour >= 12 && hour < 23)
  }
  
  initial_mode <- if (is_daytime()) "light" else "dark"
  toggle_dark_mode(mode = initial_mode, session = session)
  
  observe({
    if (is_daytime()) {
      toggle_dark_mode(mode = "light", session = session)
    } else {
      toggle_dark_mode(mode = "dark", session = session)
    }
  })
}

shinyApp(ui, server)
